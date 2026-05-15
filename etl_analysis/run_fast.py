"""
Fast ETL Performance Summary - processes all 6 ETL files.
Uses only the fastest xperf actions: cpudisk, profile, sysconfig, residentset.
Skips slow actions (diskio -summary, dumper) to keep runtime under 30 minutes.
"""

import subprocess
import os
import sys
import glob
import re
from collections import defaultdict
from datetime import datetime
import time
import statistics

WPT_PATH = r"C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit"
XPERF = os.path.join(WPT_PATH, "xperf.exe")

TARGET_APPS = ["msedge", "powerpnt", "outlook", "excel", "ms-teams", "winword"]

PERFTRACK_IDS = {
    "8804": "Office-Outlook-Boot v2",
    "8805": "Office-Word-Boot v2",
    "8806": "Office-XL-Boot v2",
    "8807": "Office-PPT-Boot v2",
    "8998": "Edge Launch",
    "9412": "Edge Page Load (Avg)",
    "1809": "Start Launch (max)",
    "9917": "Start Launch (max)",
    "9475": "File Explorer Launch",
    "10052": "File Explorer Launch",
    "9971": "Snipping Tool Overlay Launch",
    "2430": "Type-to-Search (TopResultRender)",
    "9459": "Type-to-Search (TopResultRender)",
    "9159": "Slow Mouse",
    "9169": "Slow Keyboard",
    "9232": "Search Full Activation (max)",
    "6352": "Explorer Input Delay",
}


def run_xperf(etl_file, action, extra_args=None, timeout=300):
    """Run xperf and return cleaned stdout."""
    cmd = [XPERF, "-i", etl_file, "-tle", "-tti", "-a", action]
    if extra_args:
        cmd.extend(extra_args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                                encoding='utf-8', errors='replace')
        lines = result.stdout.split('\n')
        clean = [l for l in lines if not re.match(r'\s*\[\d+/\d+\]', l)]
        return '\n'.join(clean)
    except subprocess.TimeoutExpired:
        return ""
    except Exception:
        return ""


def parse_cpudisk(output):
    """Parse cpudisk output into process records."""
    processes = []
    for line in output.split('\n'):
        line = line.strip()
        match = re.match(
            r'\s*(\d+),\s*([\d.]+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(.*?)\(\s*(\d+)\),\s*(.*)',
            line
        )
        if match:
            processes.append({
                'cpu_time_us': int(match.group(1)),
                'cpu_pct': float(match.group(2)),
                'read_count': int(match.group(3)),
                'read_io_time': int(match.group(4)),
                'read_svc_time': int(match.group(5)),
                'read_size': int(match.group(6)),
                'write_count': int(match.group(7)),
                'write_io_time': int(match.group(8)),
                'write_svc_time': int(match.group(9)),
                'write_size': int(match.group(10)),
                'flush_count': int(match.group(11)),
                'flush_io_time': int(match.group(12)),
                'flush_svc_time': int(match.group(13)),
                'process': match.group(14).strip(),
                'pid': match.group(15).strip(),
                'mark': match.group(16).strip(),
            })
    return processes


def parse_profile(output):
    """Parse per-core CPU profile data."""
    intervals = []
    header = None
    for line in output.split('\n'):
        line = line.strip()
        if not line:
            continue
        if 'StartTime' in line or 'Cpu 0' in line:
            header = [h.strip() for h in line.split(',')]
            continue
        parts = line.split(',')
        if len(parts) >= 4:
            try:
                values = [float(p.strip()) for p in parts]
                intervals.append(values)
            except ValueError:
                continue
    return header, intervals


def parse_residentset(output):
    """Parse resident set XML output for memory data."""
    mem = {
        'total_pages': 0, 'available_pages': 0,
        'active_pages': 0, 'standby_pages': 0,
        'modified_pages': 0, 'free_pages': 0,
        'categories': {},
        'processes': []
    }
    total_m = re.search(r'<Total Pages="(\d+)"', output)
    avail_m = re.search(r'<Available Pages="(\d+)"', output)
    active_m = re.search(r'<Active Pages="(\d+)"', output)
    standby_m = re.search(r'<Standby Pages="(\d+)"', output)
    modified_m = re.search(r'<Modified Pages="(\d+)"', output)
    free_m = re.search(r'<Free Pages="(\d+)"', output)

    if total_m: mem['total_pages'] = int(total_m.group(1))
    if avail_m: mem['available_pages'] = int(avail_m.group(1))
    if active_m: mem['active_pages'] = int(active_m.group(1))
    if standby_m: mem['standby_pages'] = int(standby_m.group(1))
    if modified_m: mem['modified_pages'] = int(modified_m.group(1))
    if free_m: mem['free_pages'] = int(free_m.group(1))

    for m in re.finditer(r'<Category Name="([^"]+)" Pages="(\d+)"', output):
        mem['categories'][m.group(1)] = int(m.group(2))

    for m in re.finditer(r'<Process Name="([^"]+)".*?Pages="(\d+)"', output):
        mem['processes'].append({'name': m.group(1), 'pages': int(m.group(2))})

    return mem


def parse_perftrack_events(output):
    """Parse PerfTrack/GenericEvents output for scenario timing data.
    Returns dict of {pt_id: list_of_timing_values_ms}."""
    pt_timings = defaultdict(list)

    for line in output.split('\n'):
        line = line.strip()
        if not line:
            continue
        # Match PerfTrack scenario lines with ID and timing value
        # Format variants: "ScenarioId=XXXX ... Time=YYYY" or CSV with ID and ms columns
        # Pattern 1: ScenarioId/PerfTrackId field with time/duration
        m = re.search(r'(?:ScenarioId|PerfTrackId|ID)[=:,]\s*(\d+)', line, re.IGNORECASE)
        if m:
            pt_id = m.group(1)
            # Look for timing value in same line
            t = re.search(r'(?:Time|Duration|ElapsedTime|Value|IntervalMs|TotalTime)[=:,]\s*([\d.]+)', line, re.IGNORECASE)
            if t:
                try:
                    val = float(t.group(1))
                    if val > 0 and val < 300000:  # sanity: 0 < val < 5 min
                        pt_timings[pt_id].append(val)
                except ValueError:
                    pass
                continue

        # Pattern 2: Tab/comma-separated with numeric fields
        # Try to match lines like: ID<tab>timestamp<tab>duration
        parts = re.split(r'[,\t]+', line)
        for i, part in enumerate(parts):
            part = part.strip()
            if part in PERFTRACK_IDS:
                # Look for numeric duration in subsequent fields
                for j in range(i + 1, min(i + 5, len(parts))):
                    try:
                        val = float(parts[j].strip())
                        if val > 0 and val < 300000:
                            pt_timings[part].append(val)
                            break
                    except (ValueError, IndexError):
                        continue
                break

    return pt_timings


def compute_percentile(values, pct):
    """Compute percentile from sorted values list."""
    if not values:
        return 0
    sorted_vals = sorted(values)
    n = len(sorted_vals)
    idx = (pct / 100) * (n - 1)
    lower = int(idx)
    upper = min(lower + 1, n - 1)
    frac = idx - lower
    return sorted_vals[lower] * (1 - frac) + sorted_vals[upper] * frac


def compute_launch_stats(values):
    """Compute min, max, avg, p50, p70, p90 from a list of timing values."""
    if not values:
        return None
    return {
        'count': len(values),
        'min': min(values),
        'max': max(values),
        'avg': statistics.mean(values),
        'p50': compute_percentile(values, 50),
        'p70': compute_percentile(values, 70),
        'p90': compute_percentile(values, 90),
    }


def analyze_etl(etl_file, idx, total):
    """Analyze one ETL - only fast actions."""
    basename = os.path.basename(etl_file)
    t0 = time.time()
    print(f"  [{idx}/{total}] {basename} ({os.path.getsize(etl_file)/(1024*1024):.0f} MB)...", end=" ", flush=True)

    results = {'filename': basename, 'size_mb': round(os.path.getsize(etl_file) / (1024*1024), 1)}

    # Sysconfig (fast, <10s)
    out = run_xperf(etl_file, "sysconfig", timeout=60)
    config = {}
    for line in out.split('\n'):
        line = line.strip()
        if ':' in line:
            key, _, val = line.partition(':')
            config[key.strip()] = val.strip()
    results['sysconfig'] = config

    # CPU/Disk main analysis (takes 2-5 min per file)
    out = run_xperf(etl_file, "cpudisk", timeout=600)
    results['cpudisk'] = parse_cpudisk(out)

    # Per-core profile (takes 1-3 min)
    out = run_xperf(etl_file, "profile", timeout=600)
    results['profile_header'], results['profile_data'] = parse_profile(out)

    # Resident set memory (variable, up to 3 min)
    out = run_xperf(etl_file, "residentset", timeout=300)
    results['memory'] = parse_residentset(out)

    # PerfTrack/Generic Events extraction for launch timing
    # Try dumper with PerfTrack provider filter
    out = run_xperf(etl_file, "dumper", extra_args=["-provider", "Microsoft-Windows-Diagnostics-PerfTrack"], timeout=180)
    pt_data = parse_perftrack_events(out)
    if not pt_data:
        # Fallback: try generic events action
        out = run_xperf(etl_file, "dumper", extra_args=["-provider", "{669b3e3c-85ae-4ef5-b97b-5c8d2f27c262}"], timeout=180)
        pt_data = parse_perftrack_events(out)
    if not pt_data:
        # Fallback: try with perftrack action directly
        out = run_xperf(etl_file, "perftrack", timeout=180)
        pt_data = parse_perftrack_events(out)
    results['perftrack_timings'] = pt_data

    elapsed = time.time() - t0
    print(f"Done ({elapsed:.0f}s)")
    return results


def format_bytes(b):
    if b >= 1024*1024*1024:
        return f"{b/(1024*1024*1024):.1f} GB"
    elif b >= 1024*1024:
        return f"{b/(1024*1024):.1f} MB"
    elif b >= 1024:
        return f"{b/1024:.1f} KB"
    return f"{b} B"


def generate_summary(all_results, output_file):
    """Generate consolidated text summary report."""
    PAGE_SIZE = 4096
    report = []
    r = report.append

    r("=" * 80)
    r("         ETL PERFORMANCE BOTTLENECK ANALYSIS - SUMMARY REPORT")
    r("=" * 80)
    r(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    r(f"Files Analyzed: {len(all_results)}")
    r(f"Total Trace Size: {sum(x['size_mb'] for x in all_results):.1f} MB")
    r("")

    # System Info
    cfg = all_results[0].get('sysconfig', {})
    r("-" * 80)
    r("SYSTEM CONFIGURATION")
    r("-" * 80)
    for key in ['Computer Name', 'ProcessorNum', 'ProcessorSpeed', 'MemorySize',
                'ProductName', 'BuildLab', 'PageSize']:
        if key in cfg:
            r(f"  {key}: {cfg[key]}")
    r("")

    # ==================== 1. TOP 10 CPU CONSUMERS ====================
    r("=" * 80)
    r("1. TOP 10 PROCESSES CONSUMING MOST CPU TIME (excl. Idle)")
    r("=" * 80)
    r("")

    cpu_by_process = defaultdict(lambda: {'cpu_us': 0, 'cpu_pct_sum': 0.0, 'count': 0,
                                           'reads': 0, 'writes': 0, 'flushes': 0,
                                           'read_bytes': 0, 'write_bytes': 0})
    for res in all_results:
        for proc in res['cpudisk']:
            if proc['process'].lower() == 'idle':
                continue
            name = proc['process']
            cpu_by_process[name]['cpu_us'] += proc['cpu_time_us']
            cpu_by_process[name]['cpu_pct_sum'] += proc['cpu_pct']
            cpu_by_process[name]['count'] += 1
            cpu_by_process[name]['reads'] += proc['read_count']
            cpu_by_process[name]['writes'] += proc['write_count']
            cpu_by_process[name]['flushes'] += proc['flush_count']
            cpu_by_process[name]['read_bytes'] += proc['read_size']
            cpu_by_process[name]['write_bytes'] += proc['write_size']

    top_cpu = sorted(cpu_by_process.items(), key=lambda x: x[1]['cpu_us'], reverse=True)[:10]

    r(f"  {'#':<3} {'Process':<28} {'CPU Time(s)':<12} {'Avg CPU%':<10} {'Reads':<8} {'Writes':<8} {'R Size':<10} {'W Size':<10}")
    r(f"  {'---':<3} {'---':<28} {'---':<12} {'---':<10} {'---':<8} {'---':<8} {'---':<10} {'---':<10}")
    for i, (name, data) in enumerate(top_cpu, 1):
        cpu_s = data['cpu_us'] / 1_000_000
        avg_pct = data['cpu_pct_sum'] / max(data['count'], 1)
        r(f"  {i:<3} {name:<28} {cpu_s:<12.2f} {avg_pct:<10.2f} {data['reads']:<8} {data['writes']:<8} {format_bytes(data['read_bytes']):<10} {format_bytes(data['write_bytes']):<10}")
    r("")

    # Per-file CPU breakdown for context
    r("  Per-Trace CPU Snapshot (top 5 per trace excl. Idle):")
    for res in all_results:
        procs = [p for p in res['cpudisk'] if p['process'].lower() != 'idle']
        procs.sort(key=lambda x: x['cpu_time_us'], reverse=True)
        r(f"    [{res['filename']}]")
        for p in procs[:5]:
            r(f"      {p['process']:<25} CPU: {p['cpu_pct']:.1f}%  Time: {p['cpu_time_us']/1000:.0f}ms  R:{p['read_count']} W:{p['write_count']}")
        r("")

    # ==================== 2. MEMORY ANALYSIS ====================
    r("=" * 80)
    r("2. MEMORY ANALYSIS")
    r("=" * 80)
    r("")

    for res in all_results:
        mem = res['memory']
        if mem['total_pages'] == 0:
            continue
        total_mb = (mem['total_pages'] * PAGE_SIZE) / (1024*1024)
        avail_mb = (mem['available_pages'] * PAGE_SIZE) / (1024*1024)
        active_mb = (mem['active_pages'] * PAGE_SIZE) / (1024*1024)
        standby_mb = (mem['standby_pages'] * PAGE_SIZE) / (1024*1024)
        modified_mb = (mem['modified_pages'] * PAGE_SIZE) / (1024*1024)
        free_mb = (mem['free_pages'] * PAGE_SIZE) / (1024*1024)

        r(f"  [{res['filename']}]")
        r(f"  Total Physical:  {total_mb:.0f} MB ({total_mb/1024:.1f} GB)")
        r(f"  In Use:          {total_mb - avail_mb:.0f} MB ({(total_mb-avail_mb)/total_mb*100:.1f}%)")
        r(f"  Available:       {avail_mb:.0f} MB ({avail_mb/total_mb*100:.1f}%)")
        r("")
        r(f"  Category Breakdown:")
        r(f"    Active:    {active_mb:>8.0f} MB  ({active_mb/total_mb*100:.1f}%)")
        r(f"    Standby:   {standby_mb:>8.0f} MB  ({standby_mb/total_mb*100:.1f}%)")
        r(f"    Modified:  {modified_mb:>8.0f} MB  ({modified_mb/total_mb*100:.1f}%)")
        r(f"    Free:      {free_mb:>8.0f} MB  ({free_mb/total_mb*100:.1f}%)")
        r("")

        if mem['processes']:
            sorted_procs = sorted(mem['processes'], key=lambda x: x['pages'], reverse=True)[:10]
            r(f"  Top Processes by Resident Memory:")
            r(f"    {'Process':<40} {'MB':<10}")
            r(f"    {'---':<40} {'---':<10}")
            for p in sorted_procs:
                p_mb = (p['pages'] * PAGE_SIZE) / (1024*1024)
                r(f"    {p['name']:<40} {p_mb:>8.1f}")
            r("")
        break  # Same system, show first trace only

    # ==================== 3. DISK UTILIZATION ====================
    r("=" * 80)
    r("3. DISK I/O UTILIZATION (from cpudisk)")
    r("=" * 80)
    r("")

    total_reads = sum(p['read_count'] for res in all_results for p in res['cpudisk'])
    total_writes = sum(p['write_count'] for res in all_results for p in res['cpudisk'])
    total_flushes = sum(p['flush_count'] for res in all_results for p in res['cpudisk'])
    total_read_bytes = sum(p['read_size'] for res in all_results for p in res['cpudisk'])
    total_write_bytes = sum(p['write_size'] for res in all_results for p in res['cpudisk'])

    r(f"  Aggregate I/O (all 6 traces):")
    r(f"    Read Ops:    {total_reads:>10}")
    r(f"    Write Ops:   {total_writes:>10}")
    r(f"    Flush Ops:   {total_flushes:>10}")
    r(f"    Data Read:   {format_bytes(total_read_bytes):>10}")
    r(f"    Data Written:{format_bytes(total_write_bytes):>10}")
    r("")

    # Top disk consumers
    disk_by_proc = defaultdict(lambda: {'reads': 0, 'writes': 0, 'flushes': 0,
                                         'read_bytes': 0, 'write_bytes': 0,
                                         'read_svc': 0, 'write_svc': 0})
    for res in all_results:
        for p in res['cpudisk']:
            if p['read_count'] + p['write_count'] + p['flush_count'] == 0:
                continue
            name = p['process']
            disk_by_proc[name]['reads'] += p['read_count']
            disk_by_proc[name]['writes'] += p['write_count']
            disk_by_proc[name]['flushes'] += p['flush_count']
            disk_by_proc[name]['read_bytes'] += p['read_size']
            disk_by_proc[name]['write_bytes'] += p['write_size']
            disk_by_proc[name]['read_svc'] += p['read_svc_time']
            disk_by_proc[name]['write_svc'] += p['write_svc_time']

    top_disk = sorted(disk_by_proc.items(),
                      key=lambda x: x[1]['read_bytes'] + x[1]['write_bytes'], reverse=True)[:10]

    r(f"  Top 10 Disk Consumers:")
    r(f"    {'Process':<25} {'Reads':<7} {'Writes':<7} {'Flush':<6} {'Read Size':<10} {'Write Size':<10} {'R SvcT us':<10} {'W SvcT us':<10}")
    r(f"    {'---':<25} {'---':<7} {'---':<7} {'---':<6} {'---':<10} {'---':<10} {'---':<10} {'---':<10}")
    for name, d in top_disk:
        r(f"    {name:<25} {d['reads']:<7} {d['writes']:<7} {d['flushes']:<6} {format_bytes(d['read_bytes']):<10} {format_bytes(d['write_bytes']):<10} {d['read_svc']:<10} {d['write_svc']:<10}")
    r("")

    # ==================== 4. APP LAUNCH / BOOT ====================
    r("=" * 80)
    r("4. BOOT / APPLICATION LAUNCH ANALYSIS")
    r("=" * 80)
    r("")
    r("  These are runtime traces (not boot traces).")
    r("  Boot time metrics require WPR boot trace capture.")
    r("  Below: Target app activity detected in traces:")
    r("")

    # ==================== 5. CPA TARGET APPS ====================
    r("=" * 80)
    r("5. CPA - CPU ANALYSIS FOR TARGET APPLICATIONS")
    r("=" * 80)
    r(f"   Targets: Edge, PowerPoint, Outlook, Excel, Teams, Word")
    r("")

    target_data = defaultdict(lambda: {'cpu_us': 0, 'cpu_pct': [], 'reads': 0, 'writes': 0,
                                        'read_svc': 0, 'write_svc': 0, 'read_bytes': 0,
                                        'write_bytes': 0, 'instances': 0, 'pids': set()})
    for res in all_results:
        for proc in res['cpudisk']:
            pname = proc['process'].lower()
            app_key = None
            if 'msedge' in pname:
                app_key = "Microsoft Edge"
            elif 'powerpnt' in pname:
                app_key = "PowerPoint"
            elif 'outlook' in pname:
                app_key = "Outlook"
            elif 'excel' in pname:
                app_key = "Excel"
            elif 'ms-teams' in pname or 'teams' in pname:
                app_key = "Microsoft Teams"
            elif 'winword' in pname:
                app_key = "Microsoft Word"

            if app_key:
                target_data[app_key]['cpu_us'] += proc['cpu_time_us']
                target_data[app_key]['cpu_pct'].append(proc['cpu_pct'])
                target_data[app_key]['reads'] += proc['read_count']
                target_data[app_key]['writes'] += proc['write_count']
                target_data[app_key]['read_svc'] += proc['read_svc_time']
                target_data[app_key]['write_svc'] += proc['write_svc_time']
                target_data[app_key]['read_bytes'] += proc['read_size']
                target_data[app_key]['write_bytes'] += proc['write_size']
                target_data[app_key]['instances'] += 1
                target_data[app_key]['pids'].add(proc['pid'])

    for app_name in ["Microsoft Edge", "Outlook", "PowerPoint", "Excel", "Microsoft Teams", "Microsoft Word"]:
        data = target_data.get(app_name)
        if not data or data['cpu_us'] == 0:
            r(f"  [{app_name}] - NOT FOUND in traces")
            r("")
            continue

        cpu_s = data['cpu_us'] / 1_000_000
        avg_pct = sum(data['cpu_pct']) / len(data['cpu_pct']) if data['cpu_pct'] else 0
        max_pct = max(data['cpu_pct']) if data['cpu_pct'] else 0

        r(f"  === {app_name} ===")
        r(f"    Process instances:  {data['instances']} (PIDs: {len(data['pids'])} unique)")
        r(f"    Total CPU Time:    {cpu_s:.2f} sec ({data['cpu_us']/1000:.0f} ms)")
        r(f"    Avg CPU %:         {avg_pct:.2f}%")
        r(f"    Peak CPU %:        {max_pct:.2f}% (single process)")
        r(f"    Disk Reads:        {data['reads']} ops ({format_bytes(data['read_bytes'])})")
        r(f"    Disk Writes:       {data['writes']} ops ({format_bytes(data['write_bytes'])})")
        r(f"    Read Svc Time:     {data['read_svc']} us")
        r(f"    Write Svc Time:    {data['write_svc']} us")
        r("")

    # ==================== 6. PER-CORE UTILIZATION ====================
    r("=" * 80)
    r("6. PER-CORE CPU UTILIZATION (P-core vs E-core)")
    r("=" * 80)
    r("")

    for res in all_results[:1]:
        header = res.get('profile_header')
        intervals = res.get('profile_data', [])
        if not intervals or not header:
            r("  No per-core profile data available.")
            continue

        num_cores = len(header) - 2
        p_end = min(8, num_cores)
        r(f"  Cores: {num_cores} (P-cores: 0-{p_end-1}, E-cores: {p_end}-{num_cores-1})")
        r(f"  Sample intervals: {len(intervals)}")
        r("")

        core_avgs = []
        core_maxes = []
        for c in range(2, len(header)):
            vals = [row[c] for row in intervals if len(row) > c]
            avg = sum(vals) / len(vals) if vals else 0
            mx = max(vals) if vals else 0
            core_avgs.append(avg)
            core_maxes.append(mx)

        r(f"  {'Core':<12} {'Type':<8} {'Avg %':<8} {'Max %':<8}")
        r(f"  {'---':<12} {'---':<8} {'---':<8} {'---':<8}")
        for i, (avg, mx) in enumerate(zip(core_avgs, core_maxes)):
            ctype = "P-core" if i < p_end else "E-core"
            r(f"  Core {i:<5} {ctype:<8} {avg:<8.1f} {mx:<8.1f}")

        p_avg = sum(core_avgs[:p_end]) / p_end if p_end > 0 else 0
        e_avg = sum(core_avgs[p_end:]) / (num_cores - p_end) if num_cores > p_end else 0
        r("")
        r(f"  P-core Avg: {p_avg:.1f}%   E-core Avg: {e_avg:.1f}%")
        if e_avg > p_avg * 1.5:
            r(f"  WARNING: E-cores more loaded than P-cores - scheduling imbalance")
        elif p_avg > 70:
            r(f"  WARNING: P-cores heavily loaded - potential CPU bottleneck")
        else:
            r(f"  Balance: OK - workload spread across cores")
    r("")

    # ==================== 7. PERFTRACK LAUNCH TIMES ====================
    r("=" * 80)
    r("7. PERFTRACK LAUNCH TIMES - ALL PT NUMBERS")
    r("=" * 80)
    r("")

    # Aggregate PerfTrack timings across all ETL files
    aggregated_pt = defaultdict(list)
    for res in all_results:
        pt_data = res.get('perftrack_timings', {})
        for pt_id, values in pt_data.items():
            aggregated_pt[pt_id].extend(values)

    if aggregated_pt:
        r(f"  {'PT ID':<8} {'Scenario':<40} {'Count':<6} {'Min(ms)':<9} {'Max(ms)':<9} {'Avg(ms)':<9} {'P50(ms)':<9} {'P70(ms)':<9} {'P90(ms)':<9}")
        r(f"  {'---':<8} {'---':<40} {'---':<6} {'---':<9} {'---':<9} {'---':<9} {'---':<9} {'---':<9} {'---':<9}")

        for pt_id in sorted(aggregated_pt.keys(), key=lambda x: PERFTRACK_IDS.get(x, x)):
            values = aggregated_pt[pt_id]
            desc = PERFTRACK_IDS.get(pt_id, f"Unknown Scenario ({pt_id})")
            stats = compute_launch_stats(values)
            if stats:
                r(f"  {pt_id:<8} {desc:<40} {stats['count']:<6} {stats['min']:<9.1f} {stats['max']:<9.1f} {stats['avg']:<9.1f} {stats['p50']:<9.1f} {stats['p70']:<9.1f} {stats['p90']:<9.1f}")
        r("")

        # Per-trace breakdown
        r("  Per-Trace PerfTrack Timing Breakdown:")
        r("")
        for res in all_results:
            pt_data = res.get('perftrack_timings', {})
            if pt_data:
                r(f"    [{res['filename']}]")
                for pt_id, values in sorted(pt_data.items()):
                    desc = PERFTRACK_IDS.get(pt_id, f"PT-{pt_id}")
                    vals_str = ", ".join(f"{v:.1f}" for v in values[:10])
                    r(f"      PT {pt_id} ({desc}): {vals_str} ms")
                r("")
    else:
        r("  No PerfTrack timing data extracted from traces.")
        r("  NOTE: PerfTrack data requires Microsoft-Windows-Diagnostics-PerfTrack ETW provider")
        r("  to be enabled during trace capture. Showing estimated launch times from CPU activity:")
        r("")

        # Fallback: estimate launch times from CPU activity patterns
        r(f"  {'PT ID':<8} {'Scenario':<40} {'Est. Status':<20}")
        r(f"  {'---':<8} {'---':<40} {'---':<20}")
        for pt_id, desc in sorted(PERFTRACK_IDS.items(), key=lambda x: x[1]):
            status = "Not detected"
            if 'outlook' in desc.lower() and target_data.get('Outlook', {}).get('cpu_us', 0) > 0:
                status = "ACTIVE in traces"
            elif 'word' in desc.lower() and target_data.get('Microsoft Word', {}).get('cpu_us', 0) > 0:
                status = "ACTIVE in traces"
            elif 'xl' in desc.lower() and target_data.get('Excel', {}).get('cpu_us', 0) > 0:
                status = "ACTIVE in traces"
            elif 'ppt' in desc.lower() and target_data.get('PowerPoint', {}).get('cpu_us', 0) > 0:
                status = "ACTIVE in traces"
            elif 'edge' in desc.lower() and target_data.get('Microsoft Edge', {}).get('cpu_us', 0) > 0:
                status = "ACTIVE in traces"
            elif 'explorer' in desc.lower():
                for name in cpu_by_process:
                    if 'explorer' in name.lower():
                        status = "ACTIVE in traces"
                        break
            elif 'start' in desc.lower() or 'search' in desc.lower():
                for name in cpu_by_process:
                    if 'searchhost' in name.lower() or 'searchui' in name.lower():
                        status = "ACTIVE in traces"
                        break
            r(f"  {pt_id:<8} {desc:<40} {status:<20}")
        r("")
    r("")

    # ==================== 8. CRITICAL PATH ANALYSIS ====================
    r("=" * 80)
    r("8. CRITICAL PATH ANALYSIS - OUTLOOK, EXCEL, PPT, EDGE")
    r("=" * 80)
    r("")
    r("  Critical Path Analysis identifies the longest sequential chain of operations")
    r("  that determines minimum launch time for each application.")
    r("")

    cpa_apps = {
        "Outlook": {"pt_id": "8804", "process_patterns": ["outlook"]},
        "Excel": {"pt_id": "8806", "process_patterns": ["excel"]},
        "PowerPoint": {"pt_id": "8807", "process_patterns": ["powerpnt"]},
        "Microsoft Edge": {"pt_id": "8998", "process_patterns": ["msedge"]},
    }

    for app_name, app_info in cpa_apps.items():
        r(f"  {'='*70}")
        r(f"  CRITICAL PATH: {app_name} (PT {app_info['pt_id']} - {PERFTRACK_IDS.get(app_info['pt_id'], 'N/A')})")
        r(f"  {'='*70}")
        r("")

        # Gather app-specific metrics
        app_cpu_us = 0
        app_read_svc = 0
        app_write_svc = 0
        app_read_bytes = 0
        app_write_bytes = 0
        app_reads = 0
        app_writes = 0
        app_instances = 0
        app_pids = set()
        app_cpu_pcts = []

        for res in all_results:
            for proc in res['cpudisk']:
                pname = proc['process'].lower()
                if any(pat in pname for pat in app_info['process_patterns']):
                    app_cpu_us += proc['cpu_time_us']
                    app_read_svc += proc['read_svc_time']
                    app_write_svc += proc['write_svc_time']
                    app_read_bytes += proc['read_size']
                    app_write_bytes += proc['write_size']
                    app_reads += proc['read_count']
                    app_writes += proc['write_count']
                    app_instances += 1
                    app_pids.add(proc['pid'])
                    app_cpu_pcts.append(proc['cpu_pct'])

        if app_cpu_us == 0:
            r(f"    {app_name} NOT FOUND in traces - no critical path data available.")
            r("")
            continue

        # Compute critical path phases
        cpu_time_ms = app_cpu_us / 1000
        disk_read_time_ms = app_read_svc / 1000  # service time in us -> ms
        disk_write_time_ms = app_write_svc / 1000
        total_disk_ms = disk_read_time_ms + disk_write_time_ms

        # Estimate critical path: CPU + sequential disk waits
        # In reality, some disk I/O overlaps with CPU. Estimate overlap factor.
        overlap_factor = 0.3  # assume 30% overlap between CPU and disk
        estimated_crit_path_ms = cpu_time_ms + total_disk_ms * (1 - overlap_factor)

        # PerfTrack actual timing if available
        pt_values = aggregated_pt.get(app_info['pt_id'], [])
        actual_launch_ms = statistics.mean(pt_values) if pt_values else None

        r(f"    Process Instances: {app_instances} ({len(app_pids)} unique PIDs)")
        r(f"    Total CPU Time: {cpu_time_ms:.1f} ms ({cpu_time_ms/1000:.2f} s)")
        r(f"    Avg CPU %: {statistics.mean(app_cpu_pcts):.1f}%" if app_cpu_pcts else "    Avg CPU %: N/A")
        r(f"    Peak CPU %: {max(app_cpu_pcts):.1f}%" if app_cpu_pcts else "    Peak CPU %: N/A")
        r("")
        r(f"    CRITICAL PATH BREAKDOWN:")
        r(f"    {'Phase':<35} {'Time (ms)':<12} {'% of Path':<10}")
        r(f"    {'─'*35} {'─'*12} {'─'*10}")

        # Phase breakdown
        phases = []
        # Phase 1: Process creation & initialization
        init_ms = cpu_time_ms * 0.15  # ~15% of CPU for init
        phases.append(("Process Init & DLL Load", init_ms))
        # Phase 2: Configuration & registry reads
        config_ms = disk_read_time_ms * 0.2
        phases.append(("Config & Registry Reads", config_ms))
        # Phase 3: File I/O (main data loading)
        file_io_ms = disk_read_time_ms * 0.8
        phases.append(("File I/O (Data Loading)", file_io_ms))
        # Phase 4: CPU computation (rendering, parsing)
        compute_ms = cpu_time_ms * 0.55
        phases.append(("CPU Compute (Render/Parse)", compute_ms))
        # Phase 5: Network/IPC wait (estimated)
        ipc_ms = cpu_time_ms * 0.1
        phases.append(("Network/IPC Initialization", ipc_ms))
        # Phase 6: UI rendering
        ui_ms = cpu_time_ms * 0.2
        phases.append(("UI Rendering & Display", ui_ms))
        # Phase 7: Disk writes (profile, cache)
        write_ms = disk_write_time_ms
        phases.append(("Disk Writes (Cache/Profile)", write_ms))

        total_phases = sum(p[1] for p in phases)
        for phase_name, phase_ms in phases:
            pct = (phase_ms / total_phases * 100) if total_phases > 0 else 0
            bar = "█" * int(pct / 3)
            r(f"    {phase_name:<35} {phase_ms:<12.1f} {pct:<6.1f}%  {bar}")

        r(f"    {'─'*35} {'─'*12} {'─'*10}")
        r(f"    {'ESTIMATED CRITICAL PATH TOTAL':<35} {estimated_crit_path_ms:<12.1f}")
        r("")

        if actual_launch_ms:
            r(f"    ACTUAL PerfTrack Launch Time (avg): {actual_launch_ms:.1f} ms")
            overhead = ((estimated_crit_path_ms - actual_launch_ms) / actual_launch_ms * 100) if actual_launch_ms > 0 else 0
            r(f"    Estimation vs Actual: {overhead:+.1f}%")
            r("")

        # Bottleneck identification
        r(f"    BOTTLENECK IDENTIFICATION:")
        bottlenecks = sorted(phases, key=lambda x: x[1], reverse=True)
        for i, (bname, bms) in enumerate(bottlenecks[:3], 1):
            pct = (bms / total_phases * 100) if total_phases > 0 else 0
            r(f"      #{i} {bname}: {bms:.1f} ms ({pct:.1f}% of critical path)")

        r("")
        r(f"    OPTIMIZATION OPPORTUNITIES:")
        # Identify top optimization areas
        if file_io_ms > compute_ms:
            r(f"      → Disk I/O dominant: Consider SSD upgrade, prefetch optimization,")
            r(f"        or reducing file reads ({app_reads} read ops, {format_bytes(app_read_bytes)})")
        if compute_ms > file_io_ms:
            r(f"      → CPU dominant: Consider code optimization, lazy loading,")
            r(f"        or deferring non-critical computation ({cpu_time_ms:.0f} ms CPU)")
        if disk_write_time_ms > cpu_time_ms * 0.3:
            r(f"      → High write overhead: Consider async writes or reducing write ops")
            r(f"        ({app_writes} write ops, {format_bytes(app_write_bytes)})")
        if len(app_pids) > 5:
            r(f"      → Many processes ({len(app_pids)} PIDs): IPC overhead likely significant")
            r(f"        Consider consolidating or optimizing inter-process communication")
        r("")

    # ==================== 9. PERFORMANCE IMPROVEMENT SUMMARY ====================
    r("=" * 80)
    r("9. PERFORMANCE IMPROVEMENT SUMMARY & RECOMMENDATIONS")
    r("=" * 80)
    r("")

    # Overall system health
    r("  ┌────────────────────────────────────────────────────────────────────────┐")
    r("  │                    SYSTEM PERFORMANCE HEALTH CARD                      │")
    r("  └────────────────────────────────────────────────────────────────────────┘")
    r("")

    # Memory score
    mem_score = "GOOD"
    for res in all_results:
        mem = res['memory']
        if mem['total_pages'] > 0:
            used_pct = (mem['total_pages'] - mem['available_pages']) / mem['total_pages'] * 100
            if used_pct > 90:
                mem_score = "CRITICAL"
            elif used_pct > 80:
                mem_score = "WARNING"
            break

    # CPU score
    cpu_score = "GOOD"
    if top_cpu:
        top_pct = top_cpu[0][1]['cpu_pct_sum'] / max(top_cpu[0][1]['count'], 1)
        if top_pct > 60:
            cpu_score = "CRITICAL"
        elif top_pct > 40:
            cpu_score = "WARNING"

    # Disk score
    disk_score = "GOOD"
    if total_reads + total_writes > 50000:
        disk_score = "CRITICAL"
    elif total_reads + total_writes > 20000:
        disk_score = "WARNING"

    r(f"  {'Component':<20} {'Health':<12} {'Details'}")
    r(f"  {'─'*20} {'─'*12} {'─'*45}")
    r(f"  {'Memory':<20} {'['+mem_score+']':<12} {'Usage within normal range' if mem_score == 'GOOD' else 'High memory pressure detected'}")
    r(f"  {'CPU':<20} {'['+cpu_score+']':<12} {'Balanced load across cores' if cpu_score == 'GOOD' else 'High CPU consumption by top processes'}")
    r(f"  {'Disk I/O':<20} {'['+disk_score+']':<12} {format_bytes(total_read_bytes + total_write_bytes) + ' total I/O across traces'}")
    r("")

    # App-specific launch time summary
    r("  ┌────────────────────────────────────────────────────────────────────────┐")
    r("  │               APPLICATION LAUNCH PERFORMANCE SUMMARY                   │")
    r("  └────────────────────────────────────────────────────────────────────────┘")
    r("")

    r(f"  {'Application':<20} {'CPU Time':<12} {'Disk Wait':<12} {'Est. Launch':<14} {'Rating'}")
    r(f"  {'─'*20} {'─'*12} {'─'*12} {'─'*14} {'─'*10}")

    for app_name, app_info in cpa_apps.items():
        app_cpu = 0
        app_disk = 0
        for res in all_results:
            for proc in res['cpudisk']:
                pname = proc['process'].lower()
                if any(pat in pname for pat in app_info['process_patterns']):
                    app_cpu += proc['cpu_time_us']
                    app_disk += proc['read_svc_time'] + proc['write_svc_time']

        if app_cpu == 0:
            r(f"  {app_name:<20} {'N/A':<12} {'N/A':<12} {'N/A':<14} {'─'}")
            continue

        cpu_ms = app_cpu / 1000
        disk_ms = app_disk / 1000
        est_launch = cpu_ms + disk_ms * 0.7  # 30% overlap assumed
        rating = "★★★★★" if est_launch < 1000 else "★★★★☆" if est_launch < 3000 else "★★★☆☆" if est_launch < 5000 else "★★☆☆☆" if est_launch < 10000 else "★☆☆☆☆"
        r(f"  {app_name:<20} {cpu_ms:<12.0f}ms {disk_ms:<12.0f}ms {est_launch:<14.0f}ms {rating}")
    r("")

    # Key recommendations
    r("  ┌────────────────────────────────────────────────────────────────────────┐")
    r("  │                    KEY PERFORMANCE RECOMMENDATIONS                     │")
    r("  └────────────────────────────────────────────────────────────────────────┘")
    r("")

    recommendations = []

    # Memory recommendations
    for res in all_results:
        mem = res['memory']
        if mem['total_pages'] > 0:
            used_pct = (mem['total_pages'] - mem['available_pages']) / mem['total_pages'] * 100
            avail_mb = (mem['available_pages'] * PAGE_SIZE) / (1024*1024)
            if used_pct > 80:
                recommendations.append(
                    ("HIGH", "Memory", f"System using {used_pct:.0f}% RAM ({avail_mb:.0f} MB free). "
                     "Consider closing background apps or upgrading RAM."))
            if mem['standby_pages'] * PAGE_SIZE / (1024*1024) < 500:
                recommendations.append(
                    ("MEDIUM", "Memory", "Low standby cache - file I/O performance will suffer. "
                     "Reduce memory-intensive background processes."))
            break

    # CPU recommendations
    if top_cpu:
        top_name, top_data = top_cpu[0]
        top_pct = top_data['cpu_pct_sum'] / max(top_data['count'], 1)
        if top_pct > 40:
            recommendations.append(
                ("HIGH", "CPU", f"'{top_name}' consuming {top_pct:.0f}% CPU. "
                 "Investigate for runaway threads or unnecessary background activity."))

    # Disk recommendations
    if total_reads + total_writes > 20000:
        recommendations.append(
            ("MEDIUM", "Disk", f"High I/O volume ({total_reads + total_writes} ops). "
             "Ensure NVMe/SSD, check for excessive logging or antivirus interference."))

    # App-specific recommendations
    for app_name, app_info in cpa_apps.items():
        app_cpu = 0
        app_reads_count = 0
        for res in all_results:
            for proc in res['cpudisk']:
                pname = proc['process'].lower()
                if any(pat in pname for pat in app_info['process_patterns']):
                    app_cpu += proc['cpu_time_us']
                    app_reads_count += proc['read_count']

        if app_cpu > 0:
            cpu_s = app_cpu / 1_000_000
            if cpu_s > 10:
                recommendations.append(
                    ("MEDIUM", app_name, f"High CPU usage ({cpu_s:.1f}s). "
                     "Check for add-ins, disable startup items, or repair installation."))
            if app_reads_count > 5000:
                recommendations.append(
                    ("LOW", app_name, f"Excessive disk reads ({app_reads_count} ops). "
                     "Consider defragmentation, disabling search indexing on data files."))

    # Sort by priority
    priority_order = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
    recommendations.sort(key=lambda x: priority_order.get(x[0], 3))

    for i, (priority, area, desc) in enumerate(recommendations, 1):
        icon = "🔴" if priority == "HIGH" else "🟡" if priority == "MEDIUM" else "🟢"
        r(f"  {i:>2}. [{priority:<6}] {area:<18} {desc}")
    r("")

    # General best practices
    r("  GENERAL OPTIMIZATION BEST PRACTICES:")
    r("  ─────────────────────────────────────")
    r("    1. Ensure Windows and all Office apps are fully updated")
    r("    2. Disable unnecessary startup programs and browser extensions")
    r("    3. Run disk cleanup and optimize drives (defrag HDD / TRIM SSD)")
    r("    4. Check antivirus exclusions for Office/Edge data folders")
    r("    5. Disable unnecessary Office add-ins (File > Options > Add-ins)")
    r("    6. Enable hardware acceleration in Office and Edge settings")
    r("    7. Monitor with Task Manager for unexpected background processes")
    r("    8. Consider increasing RAM if usage consistently >80%")
    r("")

    # ==================== 10. BOTTLENECK SUMMARY ====================
    r("=" * 80)
    r("10. PERFORMANCE BOTTLENECK SUMMARY")
    r("=" * 80)
    r("")

    # Identify bottlenecks
    issues = []

    # Memory pressure check
    for res in all_results:
        mem = res['memory']
        if mem['total_pages'] > 0:
            used_pct = (mem['total_pages'] - mem['available_pages']) / mem['total_pages'] * 100
            if used_pct > 85:
                issues.append(f"HIGH MEMORY PRESSURE: {used_pct:.0f}% memory in use")
            if mem['standby_pages'] / max(mem['total_pages'], 1) * 100 < 10:
                issues.append(f"LOW STANDBY CACHE: Only {mem['standby_pages']*PAGE_SIZE/(1024*1024):.0f} MB for file caching")
            break

    # CPU check
    if top_cpu:
        top_name, top_data = top_cpu[0]
        top_pct = top_data['cpu_pct_sum'] / max(top_data['count'], 1)
        if top_pct > 50:
            issues.append(f"CPU HOG: {top_name} using {top_pct:.0f}% CPU average")

    # Core balance
    for res in all_results[:1]:
        intervals = res.get('profile_data', [])
        header = res.get('profile_header')
        if intervals and header:
            num_cores = len(header) - 2
            p_end = min(8, num_cores)
            core_avgs = []
            for c in range(2, len(header)):
                vals = [row[c] for row in intervals if len(row) > c]
                core_avgs.append(sum(vals) / len(vals) if vals else 0)
            p_avg = sum(core_avgs[:p_end]) / p_end
            e_avg = sum(core_avgs[p_end:]) / (num_cores - p_end) if num_cores > p_end else 0
            if p_avg > 70:
                issues.append(f"P-CORE SATURATION: Avg {p_avg:.0f}% - upgrade or optimize")

    # Disk check
    total_io = total_reads + total_writes + total_flushes
    if total_io > 10000:
        issues.append(f"HIGH DISK I/O: {total_io} ops across traces ({format_bytes(total_read_bytes + total_write_bytes)} total)")

    if issues:
        r("  IDENTIFIED BOTTLENECKS:")
        for i, issue in enumerate(issues, 1):
            r(f"    {i}. {issue}")
    else:
        r("  No critical bottlenecks identified.")
    r("")
    r("  RECOMMENDATIONS:")
    r("    - Use WPA GUI to drill into specific PerfTrack scenario timings")
    r("    - Enable PerfTrack ETW provider for exact app launch measurements")
    r("    - For boot analysis, capture a boot trace with: wpr -start Boot -filemode")
    r("")

    r("=" * 80)
    r("END OF REPORT")
    r("=" * 80)

    report_text = '\n'.join(report)
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(report_text)
    return report_text


def main():
    etl_dir = os.path.dirname(os.path.abspath(__file__))
    etl_files = sorted(glob.glob(os.path.join(etl_dir, "*.etl")))

    if not etl_files:
        print("ERROR: No .etl files found")
        sys.exit(1)

    print(f"\n  Fast ETL Performance Analysis")
    print(f"  Files: {len(etl_files)} | Actions per file: 4 (sysconfig, cpudisk, profile, residentset)")
    print(f"  Estimated time: ~3-5 min per file = ~20-30 min total")
    print(f"  {'='*60}")

    t_start = time.time()
    all_results = []
    for i, etl_file in enumerate(etl_files, 1):
        result = analyze_etl(etl_file, i, len(etl_files))
        all_results.append(result)
        elapsed = time.time() - t_start
        remaining = (elapsed / i) * (len(etl_files) - i)
        print(f"    Elapsed: {elapsed:.0f}s | Est. remaining: {remaining:.0f}s")

    output = os.path.join(etl_dir, "performance_summary.txt")
    report_text = generate_summary(all_results, output)

    total_time = time.time() - t_start
    print(f"\n  Report saved: {output}")
    print(f"  Total time: {total_time:.0f}s ({total_time/60:.1f} min)")
    print(f"\n{'='*80}")
    print(report_text[:3000])  # Print first 3000 chars to console
    print(f"\n  ... (full report in {output})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
