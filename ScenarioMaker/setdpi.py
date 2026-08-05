# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Script to manually set the DPI of a specified image.

import os
from PIL import Image

ratio = 2.5
infile = "C:\\hobl_26\\scenarios\\windows\\_library\\productivity\\prod_excel_run\\image_1RWKWRX.png"

# load image from infile path
image = Image.open(infile)
dut_dpi = int(96 * ratio)

print(f"Saving template with dpi {dut_dpi}")
image.save(infile, dpi=(dut_dpi, dut_dpi))
