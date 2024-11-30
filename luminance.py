#!/usr/bin/env python
import sys

import numpy as np
from PIL import Image

def calculate_luminance_variance(image_path):
    # Load the image
    img = Image.open(image_path)
    # Convert to numpy array and normalize to 0-1 range
    img_array = np.array(img).astype(float) / 255.0
    
    # Rec. 709 coefficients for luminance
    r_coeff, g_coeff, b_coeff = 0.2126, 0.7152, 0.0722
    
    # Calculate luminance for each pixel
    luminance = (img_array[:,:,0] * r_coeff +
                img_array[:,:,1] * g_coeff +
                img_array[:,:,2] * b_coeff)
    
    # Calculate variance using different methods for verification
    
    # Method 1: Using numpy's var() function directly
    variance_np = np.var(luminance)
    
    # Method 2: Manual calculation using sum and sum-squared
    N = luminance.size
    sum_lum = np.sum(luminance)
    sum_lum_squared = np.sum(luminance ** 2)
    variance_manual = (sum_lum_squared / N) - (sum_lum / N) ** 2
    
    # Method 3: Using mean subtraction method
    mean_lum = np.mean(luminance)
    variance_mean = np.mean((luminance - mean_lum) ** 2)
    
    # Print detailed statistics
    print(f"Image statistics:")
    print(f"Dimensions: {luminance.shape}")
    print(f"Number of pixels: {N}")
    print(f"Mean luminance: {mean_lum:.6f}")
    print(f"Min luminance: {np.min(luminance):.6f}")
    print(f"Max luminance: {np.max(luminance):.6f}")
    print("\nVariance calculations:")
    print(f"Method 1 (numpy.var): {variance_np:.6f}")
    print(f"Method 2 (sum/sum-squared): {variance_manual:.6f}")
    print(f"Method 3 (mean subtraction): {variance_mean:.6f}")
    
    # Calculate histogram for distribution visualization
    hist, bins = np.histogram(luminance, bins=50, range=(0,1))
    print("\nLuminance histogram bins:", bins)
    print("Luminance histogram counts:", hist)
    
    return variance_manual

# Usage example
if __name__ == "__main__":
    variance = calculate_luminance_variance(sys.argv[1])
