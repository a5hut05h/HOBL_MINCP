# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import argparse
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, LogitsProcessor
import os
import time
from transformers.generation.streamers import TextStreamer
import sys
import shutil
import json

sys.stdout.reconfigure(encoding='utf-8')

def get_dir_size(path):
    """Calculate total size of directory"""
    total_size = 0
    try:
        for dirpath, dirnames, filenames in os.walk(path):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                if os.path.exists(filepath):
                    total_size += os.path.getsize(filepath)
    except Exception:
        pass
    return total_size

def format_size(size_bytes):
    """Format bytes to human readable format"""
    if size_bytes == 0:
        return "0 B"
    
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} PB"

def get_gpu_memory_info():
    """Get GPU memory information"""
    if not torch.cuda.is_available():
        return None
    
    try:
        allocated = torch.cuda.memory_allocated()
        reserved = torch.cuda.memory_reserved()
        max_allocated = torch.cuda.max_memory_allocated()
        return {
            'allocated': allocated,
            'reserved': reserved,
            'max_allocated': max_allocated
        }
    except Exception:
        return None

def cleanup_gpu_cache():
    """Clear GPU memory cache"""
    print("Clearing GPU memory cache...")
    
    if not torch.cuda.is_available():
        print("✗ No GPU available - nothing to clear")
        return 0
    
    # Get memory info before clearing
    before_info = get_gpu_memory_info()
    
    # Clear the cache
    torch.cuda.empty_cache()
    
    # Get memory info after clearing
    after_info = get_gpu_memory_info()
    
    if before_info and after_info:
        freed = before_info['reserved'] - after_info['reserved']
        print(f"✓ GPU cache cleared")
        print(f"  Memory freed: {format_size(freed)}")
        print(f"  Still allocated: {format_size(after_info['allocated'])}")
        return freed
    else:
        print("✓ GPU cache cleared")
        return 0

def cleanup_disk_cache():
    """Remove all cached models and tokenizers from disk"""
    print("Cleaning up disk-based model cache...")
    
    # Get HuggingFace cache directory
    cache_dir = os.path.expanduser("~/.cache/huggingface")
    transformers_cache = os.path.join(cache_dir, "transformers")
    hub_cache = os.path.join(cache_dir, "hub")
    
    # Also check for TRANSFORMERS_CACHE env variable
    env_cache = os.environ.get('TRANSFORMERS_CACHE')
    if env_cache:
        cache_dirs = [env_cache, transformers_cache, hub_cache]
    else:
        cache_dirs = [transformers_cache, hub_cache]
    
    total_size_freed = 0
    
    for cache_path in cache_dirs:
        if os.path.exists(cache_path):
            # Calculate size before deletion
            size_before = get_dir_size(cache_path)
            print(f"Removing cache directory: {cache_path}")
            print(f"  Size: {format_size(size_before)}")
            
            try:
                shutil.rmtree(cache_path)
                total_size_freed += size_before
                print(f"  ✓ Successfully removed")
            except Exception as e:
                print(f"  ✗ Failed to remove: {e}")
        else:
            print(f"Cache directory not found: {cache_path}")
    
    return total_size_freed

def cleanup_all_cache():
    """Remove all cached models and clear GPU cache"""
    print("--- Full Cache Cleanup ---")
    
    # Clear disk cache
    disk_freed = cleanup_disk_cache()
    
    print()  # Empty line for separation
    
    # Clear GPU cache
    gpu_freed = cleanup_gpu_cache()
    
    print(f"\n--- Cleanup Complete ---")
    print(f"Disk space freed: {format_size(disk_freed)}")
    if torch.cuda.is_available():
        print(f"GPU memory freed: {format_size(gpu_freed)}")
    print("All caches have been cleared")

def show_cache_info():
    """Show information about cached models and GPU memory"""
    print("--- Cache Information ---")
    
    # Disk cache info
    cache_dir = os.path.expanduser("~/.cache/huggingface")
    transformers_cache = os.path.join(cache_dir, "transformers")
    hub_cache = os.path.join(cache_dir, "hub")
    
    print("Disk Cache:")
    total_disk_cache = 0
    for cache_path in [transformers_cache, hub_cache]:
        if os.path.exists(cache_path):
            size = get_dir_size(cache_path)
            total_disk_cache += size
            print(f"  {cache_path}: {format_size(size)}")
        else:
            print(f"  {cache_path}: Not found")
    
    print(f"  Total disk cache: {format_size(total_disk_cache)}")
    
    # GPU memory info
    print("\nGPU Memory:")
    if torch.cuda.is_available():
        gpu_info = get_gpu_memory_info()
        if gpu_info:
            print(f"  Currently allocated: {format_size(gpu_info['allocated'])}")
            print(f"  Reserved by PyTorch: {format_size(gpu_info['reserved'])}")
            print(f"  Max allocated: {format_size(gpu_info['max_allocated'])}")
            
            # Total GPU memory
            total_memory = torch.cuda.get_device_properties(0).total_memory
            print(f"  Total GPU memory: {format_size(total_memory)}")
        else:
            print("  Unable to get GPU memory information")
    else:
        print("  No GPU available")

def setup_model(model_name, device):
    """Download and cache the model and tokenizer"""
    print(f"Setting up model: {model_name}")
    print(f"Target device: {device}")
    
    print("Downloading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.pad_token = tokenizer.eos_token
    special_tokens_dict = {"additional_special_tokens": ["<|user|>", "<|assistant|>"]}
    tokenizer.add_special_tokens(special_tokens_dict)
    print("✓ Tokenizer downloaded and configured")

    print("Downloading model...")
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype="auto",
        device_map="auto" if device == 'cuda' else None
    )
    # model.resize_token_embeddings(len(tokenizer))
    print("✓ Model downloaded and configured")
    
    print("\n--- Setup Complete ---")
    print(f"Model '{model_name}' is ready for inference")
    print(f"Cached location: {tokenizer.name_or_path}")
    print("You can now run inference with --prompt argument")
    
    return model, tokenizer

def run_inference(model, tokenizer, prompt, device, log_dir=None):
    """Run inference with the given prompt"""
    model = model.to(device)
    model.eval()

    # Prepare prompt
    formatted_prompt = f"<|user|>\n{prompt}\n<|assistant|>"
    tokenized = tokenizer(
        formatted_prompt,
        return_tensors="pt",
        truncation=True,
        max_length=128
    )
    input_ids = tokenized.input_ids.to(device)
    attention_mask = tokenized.attention_mask.to(device)

    # Use text streamer for real-time output and measure performance
    class StatsStreamer(TextStreamer):
        def __init__(self, tokenizer, **kwargs):
            super().__init__(tokenizer, **kwargs)
            self.token_count = 0
            self.start_time = None
            self.first_token_time = None
            self.end_time = None
            
        def put(self, value):
            if self.start_time is None:
                self.start_time = time.time()
            if self.first_token_time is None:
                self.first_token_time = time.time()
            self.token_count += 1
            super().put(value)
            
        def end(self):
            self.end_time = time.time()
            super().end()

    streamer = StatsStreamer(tokenizer, skip_prompt=True, skip_special_tokens=True)

    # Sanitize NaN/Inf logits before sampling — Phi-4-mini can produce non-finite
    # logits on Arm64 CPU due to floating-point precision differences, which causes
    # torch.multinomial to fail with "probability tensor contains inf, nan".
    class SanitizeLogitsProcessor(LogitsProcessor):
        def __call__(self, input_ids, scores):
            return torch.where(torch.isfinite(scores), scores, torch.full_like(scores, torch.finfo(scores.dtype).min))

    # Record generation start time for use with Time to First Token (TTFT)
    generation_start = time.time()
    
    with torch.no_grad():
        model.generate(
            input_ids=input_ids,
            attention_mask=attention_mask,
            max_length=256,
            do_sample=True,
            top_p=0.95,
            temperature=0.8,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
            use_cache=True,
            streamer=streamer,
            logits_processor=[SanitizeLogitsProcessor()]
        )
    print()  # Newline after streaming

    # Calculate performance metrics
    metrics = {}
    if streamer.start_time is not None and streamer.end_time is not None:
        total_time = streamer.end_time - streamer.start_time
        tokens_generated = streamer.token_count
        
        # Time to First Token (TTFT)
        if streamer.first_token_time is not None:
            ttft = streamer.first_token_time - generation_start
            metrics['time_to_first_token_ms'] = round(ttft * 1000, 2)
            metrics['time_to_first_token_s'] = round(ttft, 4)
        else:
            metrics['time_to_first_token_ms'] = 0
            metrics['time_to_first_token_s'] = 0
        
        # Tokens Per Second (TPS)
        if total_time > 0:
            tps = tokens_generated / total_time
            metrics['tokens_per_second'] = round(tps, 2)
        else:
            metrics['tokens_per_second'] = 0
        
        # Additional metrics
        metrics['total_tokens_generated'] = tokens_generated
        metrics['total_generation_time_s'] = round(total_time, 4)
        metrics['ai_model'] = model.config._name_or_path if hasattr(model.config, '_name_or_path') else 'unknown'
        metrics['ai_device'] = str(device)
        
        # Save metrics to CSV file
        output_file = 'pytorch_inference_info.csv'
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
            output_file = os.path.join(log_dir, output_file)
        
        with open(output_file, 'w') as f:
            # Write metrics as CSV
            for key, value in metrics.items():
                f.write(f"{key},{value}\n")
        
        # Print metrics to console
        print(f"\n{'='*50}")
        print(f"{'PERFORMANCE METRICS':^50}")
        print(f"{'='*50}")
        print(f"Time to First Token (TTFT): {metrics['time_to_first_token_ms']:.2f} ms")
        print(f"Tokens Per Second (TPS):    {metrics['tokens_per_second']:.2f} tokens/s")
        print(f"Total Tokens Generated:      {metrics['total_tokens_generated']}")
        print(f"Total Generation Time:       {metrics['total_generation_time_s']:.4f} s")
        print(f"AI Model:                       {metrics['ai_model']}")
        print(f"AI Device:                      {metrics['ai_device']}")
        print(f"{'='*50}")
        print(f"\nMetrics saved to: {output_file}")
        
        return metrics
    
    return None

def main():
    parser = argparse.ArgumentParser(description="Run inference on a HuggingFace model (no fine-tuning).")
    parser.add_argument('--model', type=str, default='microsoft/Phi-4-mini-instruct', help='HuggingFace model name (default: microsoft/Phi-4-mini-instruct)')
    parser.add_argument('--gpu', action=argparse.BooleanOptionalAction, default=True, help='Use GPU for inference (default: True)')
    parser.add_argument('--prompt', type=str, help='Prompt for inference (in quotes)')
    parser.add_argument('--setup', action='store_true', help='Download and setup the model for inference')
    parser.add_argument('--cleanup', action='store_true', help='Remove all cached models and clear GPU memory')
    parser.add_argument('--cleanup-gpu', action='store_true', help='Clear GPU memory cache only')
    parser.add_argument('--cache-info', action='store_true', help='Show cache information (disk and GPU)')
    parser.add_argument('--log-dir', type=str, help='Directory to save metrics CSV file (default: current directory)')
    args = parser.parse_args()

    if args.gpu and torch.cuda.is_available():
        device = 'cuda'
    elif args.gpu and hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
        device = 'mps'
    else:
        device = 'cpu'
    model_name = args.model
    
    # Check cache management modes first
    if args.cache_info:
        show_cache_info()
        return
    
    if args.cleanup:
        cleanup_all_cache()
        return
    
    if args.cleanup_gpu:
        cleanup_gpu_cache()
        return
    
    print(f"Using device: {device}")
    print(f"Using model: {model_name}")

    # Check if setup mode
    if args.setup:
        setup_model(model_name, device)
        return

    # Check if prompt is provided for inference
    if not args.prompt:
        print("Error: --prompt is required for inference. Use --setup to download the model first.")
        sys.exit(1)

    # Load tokenizer
    print("Loading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.pad_token = tokenizer.eos_token
    special_tokens_dict = {"additional_special_tokens": ["<|user|>", "<|assistant|>"]}
    tokenizer.add_special_tokens(special_tokens_dict)

    # Load base model (no LoRA, no fine-tuning)
    print("Loading model...")
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype="auto",
        device_map="auto" if device == 'cuda' else None
    )
    model.resize_token_embeddings(len(tokenizer))

    # Run inference
    run_inference(model, tokenizer, args.prompt, device, args.log_dir)

if __name__ == "__main__":
    main()
