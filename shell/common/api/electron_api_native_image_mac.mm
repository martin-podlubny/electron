// Copyright (c) 2015 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "shell/common/api/electron_api_native_image.h"

#include <string>
#include <utility>
#include <vector>

#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#include "base/apple/foundation_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "gin/arguments.h"
#include "shell/common/gin_converters/image_converter.h"
#include "shell/common/gin_helper/handle.h"
#include "shell/common/gin_helper/promise.h"
#include "shell/common/mac_util.h"
#include "ui/gfx/color_utils.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_operations.h"

namespace electron::api {

NSData* bufferFromNSImage(NSImage* image) {
  CGImageRef ref = [image CGImageForProposedRect:nil context:nil hints:nil];
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:ref];
  [rep setSize:[image size]];
  return [rep representationUsingType:NSBitmapImageFileTypePNG
                           properties:[[NSDictionary alloc] init]];
}

double safeShift(double in, double def) {
  if ((in >= 0 && in <= 1) || in == def)
    return in;
  return def;
}

void ReceivedThumbnailResult(CGSize size,
                             gin_helper::Promise<gfx::Image> p,
                             QLThumbnailRepresentation* thumbnail,
                             NSError* error) {
  if (error || !thumbnail) {
    std::string err_msg([error.localizedDescription UTF8String]);
    p.RejectWithErrorMessage("unable to retrieve thumbnail preview "
                             "image for the given path: " +
                             err_msg);
  } else {
    NSImage* result = [[NSImage alloc] initWithCGImage:[thumbnail CGImage]
                                                  size:size];
    gfx::Image image(result);
    p.Resolve(image);
  }
}

// static
v8::Local<v8::Promise> NativeImage::CreateThumbnailFromPath(
    v8::Isolate* isolate,
    const base::FilePath& path,
    const gfx::Size& size) {
  gin_helper::Promise<gfx::Image> promise(isolate);
  v8::Local<v8::Promise> handle = promise.GetHandle();

  if (size.IsEmpty()) {
    promise.RejectWithErrorMessage("size must not be empty");
    return handle;
  }

  CGSize cg_size = size.ToCGSize();

  NSURL* nsurl = base::apple::FilePathToNSURL(path);

  // We need to explicitly check if the user has passed an invalid path
  // because QLThumbnailGenerationRequest will generate a stock file icon
  // and pass silently if we do not.
  if (![[NSFileManager defaultManager] fileExistsAtPath:[nsurl path]]) {
    promise.RejectWithErrorMessage(
        "unable to retrieve thumbnail preview image for the given path");
    return handle;
  }

  NSScreen* screen = [[NSScreen screens] firstObject];
  QLThumbnailGenerationRequest* request([[QLThumbnailGenerationRequest alloc]
        initWithFileAtURL:nsurl
                     size:cg_size
                    scale:[screen backingScaleFactor]
      representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll]);
  __block auto block_callback = base::BindPostTaskToCurrentDefault(
      base::BindOnce(&ReceivedThumbnailResult, cg_size, std::move(promise)));
  auto completionHandler =
      ^(QLThumbnailRepresentation* thumbnail, NSError* error) {
        std::move(block_callback).Run(thumbnail, error);
      };
  [[QLThumbnailGenerator sharedGenerator]
      generateBestRepresentationForRequest:request
                         completionHandler:completionHandler];

  return handle;
}

gin_helper::Handle<NativeImage> NativeImage::CreateFromNamedImage(
    gin::Arguments* args,
    std::string name) {
  @autoreleasepool {
    std::vector<double> hsl_shift;

    // The string representations of NSImageNames don't match the strings
    // themselves; they instead follow the following pattern:
    //  * NSImageNameActionTemplate -> "NSActionTemplate"
    //  * NSImageNameMultipleDocuments -> "NSMultipleDocuments"
    // To account for this, we strip out "ImageName" from the passed string.
    std::string to_remove("ImageName");
    size_t pos = name.find(to_remove);
    if (pos != std::string::npos) {
      name.erase(pos, to_remove.length());
    }

    NSImage* image = [NSImage imageNamed:base::SysUTF8ToNSString(name)];

    if (!image.valid) {
      return CreateEmpty(args->isolate());
    }

    NSData* png_data = bufferFromNSImage(image);

    if (args->GetNext(&hsl_shift) && hsl_shift.size() == 3) {
      auto gfx_image = gfx::Image::CreateFrom1xPNGBytes(
          electron::util::as_byte_span(png_data));
      color_utils::HSL shift = {safeShift(hsl_shift[0], -1),
                                safeShift(hsl_shift[1], 0.5),
                                safeShift(hsl_shift[2], 0.5)};
      png_data = bufferFromNSImage(
          gfx::Image(gfx::ImageSkiaOperations::CreateHSLShiftedImage(
                         gfx_image.AsImageSkia(), shift))
              .AsNSImage());
    }

    return CreateFromPNG(args->isolate(),
                         electron::util::as_byte_span(png_data));
  }
}

void NativeImage::SetTemplateImage(bool setAsTemplate) {
  // Note: This method is mutually exclusive with SetPseudoTemplateImagePreservingColor.
  // If SetPseudoTemplateImagePreservingColor was previously called, this will apply
  // template rendering to the composite image (which is not desired).
  // Users should use one approach or the other, not both.
  [image_.AsNSImage() setTemplate:setAsTemplate];

  // Clear pseudo-template state since we're using standard template mode
  if (setAsTemplate) {
    is_pseudo_template_preserving_color_ = false;
  }
}

bool NativeImage::IsTemplateImage() {
  return [image_.AsNSImage() isTemplate];
}

bool NativeImage::IsPseudoTemplateImagePreservingColor() {
  return is_pseudo_template_preserving_color_;
}

// Helper function to decompose an image into colored and template parts using Core Image.
// Decompose: near-black (by luminance) -> template alpha; everything else -> colored.
// Threshold is in [0..1] (e.g. 0.10 for 10% brightness).
static std::pair<NSImage*, NSImage*> DecomposeImage(NSImage* source, CGFloat threshold) {
  @autoreleasepool {
    // Resolve to CGImage in sRGB, so "near-black" is predictable
    CGImageRef cg = [source CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) {
      return {nil, nil};
    }

    CGSize size = {(CGFloat)CGImageGetWidth(cg), (CGFloat)CGImageGetHeight(cg)};
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!sRGB) {
      return {nil, nil};
    }

    NSDictionary* opts = @{kCIImageColorSpace : (__bridge id)sRGB};
    CIImage* input = [[CIImage alloc] initWithCGImage:cg options:opts];

    // --- 1) Build a mask using a CIColorKernel ---
    // Using luminance so we don't need max(r,g,b). sRGB luma coefficients.
    static CIColorKernel* MaskKernel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSString* src =
          @"kernel vec4 maskForNearBlack(__sample s, float thr) {"
          @"   float a = s.a;"
          @"   // sRGB luminance (Rec. 709):"
          @"   float y = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));"
          @"   float isBlack = step(y, thr) * step(0.0, a);"
          @"   // return single-channel mask (in alpha):"
          @"   return vec4(isBlack, isBlack, isBlack, isBlack);"
          @"}";
      MaskKernel = [CIColorKernel kernelWithString:src];
    });

    CIImage* maskRGBA = [MaskKernel applyWithExtent:input.extent
                                          arguments:@[ input, @(threshold) ]];

    // Keep only one channel as alpha mask
    CIFilter* maskToAlpha = [CIFilter filterWithName:@"CIMaskToAlpha"];
    maskToAlpha[@"inputImage"] = maskRGBA;
    CIImage* maskA = maskToAlpha.outputImage;  // A=mask, RGB=irrelevant

    // --- 2) Build TEMPLATE: black with alpha = originalAlpha * mask ---
    // Extract original alpha into a grayscale
    CIFilter* extractA = [CIFilter filterWithName:@"CIColorMatrix"];
    extractA[@"inputImage"] = input;
    // Map A -> RGB=0, A -> A
    extractA[@"inputRVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    extractA[@"inputGVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    extractA[@"inputBVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    extractA[@"inputAVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:1];  // keep alpha
    extractA[@"inputBiasVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    CIImage* alphaOnly = extractA.outputImage;

    // Multiply original alpha by mask: A = A * mask
    CIFilter* multiplyAlpha = [CIFilter filterWithName:@"CIMultiplyCompositing"];
    // CIMultiplyCompositing does: dst * src (per channel). We only care about A.
    // Put alphaOnly as dst, maskA as src:
    multiplyAlpha[@"inputImage"] = maskA;
    multiplyAlpha[@"inputBackgroundImage"] = alphaOnly;
    CIImage* templAlpha = multiplyAlpha.outputImage;

    // Build black RGBA with that alpha
    CIFilter* blackWithAlpha = [CIFilter filterWithName:@"CIColorMatrix"];
    blackWithAlpha[@"inputImage"] = templAlpha;
    // Zero RGB, pass through A
    blackWithAlpha[@"inputRVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    blackWithAlpha[@"inputGVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    blackWithAlpha[@"inputBVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    blackWithAlpha[@"inputAVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:1];
    blackWithAlpha[@"inputBiasVector"] = [CIVector vectorWithX:0 Y:0 Z:0 W:0];
    CIImage* templateCI = blackWithAlpha.outputImage;

    // --- 3) Build COLORED: original with alpha knocked out where mask=1 ---
    // invMask = 1 - mask
    CIFilter* invert = [CIFilter filterWithName:@"CIColorInvert"];
    invert[@"inputImage"] = maskA;
    CIImage* invMask = invert.outputImage;

    // newAlpha = originalAlpha * invMask
    CIFilter* coloredA = [CIFilter filterWithName:@"CIMultiplyCompositing"];
    coloredA[@"inputImage"] = invMask;
    coloredA[@"inputBackgroundImage"] = alphaOnly;
    CIImage* coloredAlpha = coloredA.outputImage;

    // Replace input's alpha with newAlpha (keep RGB)
    CIFilter* replaceA = [CIFilter filterWithName:@"CIBlendWithAlphaMask"];
    replaceA[@"inputImage"] = input;  // source RGB
    replaceA[@"inputBackgroundImage"] =
        [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]];
    replaceA[@"inputMaskImage"] = coloredAlpha;  // uses mask's luminance as alpha
    CIImage* coloredCI = replaceA.outputImage;

    // --- 4) Convert to NSImage (no lazy CI surfaces lingering) ---
    CIContext* ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    CGImageRef templCG = [ctx createCGImage:templateCI fromRect:templateCI.extent];
    CGImageRef colCG = [ctx createCGImage:coloredCI fromRect:coloredCI.extent];

    NSImage* templNS = [[NSImage alloc] initWithCGImage:templCG size:size];
    NSImage* colNS = [[NSImage alloc] initWithCGImage:colCG size:size];

    CGImageRelease(templCG);
    CGImageRelease(colCG);
    CGColorSpaceRelease(sRGB);

    return {colNS, templNS};
  }
}

// Helper function to create a tinted version of the template part
static NSImage* TintTemplate(NSImage* templateImg, NSColor* tint, NSSize size) {
  @autoreleasepool {
    NSImage* tinted = [[NSImage alloc] initWithSize:size];
    [tinted lockFocus];

    [tint setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));

    [templateImg drawInRect:NSMakeRect(0, 0, size.width, size.height)
                   fromRect:NSMakeRect(0, 0, templateImg.size.width, templateImg.size.height)
                  operation:NSCompositingOperationDestinationIn
                   fraction:1.0];

    [tinted unlockFocus];
    return tinted;
  }
}

void NativeImage::SetPseudoTemplateImagePreservingColor(bool enable) {
  if (!enable) {
    // Revert to the original image behavior
    [image_.AsNSImage() setTemplate:NO];
    is_pseudo_template_preserving_color_ = false;
    return;
  }

  @autoreleasepool {
    NSImage* sourceImage = image_.AsNSImage();
    if (!sourceImage) {
      return;
    }

    // Decompose the icon into colored and template parts
    // Threshold of 0.02 means pixels with luminance < 2% are considered "pure black"
    // This is very selective - only truly black pixels get inverted
    auto [coloredPart, templatePart] = DecomposeImage(sourceImage, 0.02);

    if (!coloredPart || !templatePart) {
      return;
    }

    // Get the original image size
    NSSize iconSize = [sourceImage size];

    // Pre-create both light and dark tinted templates
    NSImage* lightTemplate = TintTemplate(templatePart, [NSColor blackColor], iconSize);
    NSImage* darkTemplate = TintTemplate(templatePart, [NSColor whiteColor], iconSize);

    // Pre-create the final composites for both appearances
    // This avoids compositing on every draw - just one image draw per frame
    NSRect fullRect = NSMakeRect(0, 0, iconSize.width, iconSize.height);

    // Light mode composite: colored parts + black template
    NSImage* lightComposite = [[NSImage alloc] initWithSize:iconSize];
    [lightComposite lockFocus];
    [coloredPart drawInRect:fullRect
                   fromRect:NSMakeRect(0, 0, coloredPart.size.width, coloredPart.size.height)
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
    [lightTemplate drawInRect:fullRect
                     fromRect:fullRect
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0];
    [lightComposite unlockFocus];

    // Dark mode composite: colored parts + white template
    NSImage* darkComposite = [[NSImage alloc] initWithSize:iconSize];
    [darkComposite lockFocus];
    [coloredPart drawInRect:fullRect
                   fromRect:NSMakeRect(0, 0, coloredPart.size.width, coloredPart.size.height)
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
    [darkTemplate drawInRect:fullRect
                    fromRect:fullRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];
    [darkComposite unlockFocus];

    // Create an NSImage with a drawing handler that just picks the right composite
    NSImage* composite = [NSImage imageWithSize:iconSize
                                        flipped:NO
                                 drawingHandler:^BOOL(NSRect destRect) {
      // Get the current appearance
      NSAppearance* appearance = [NSAppearance currentAppearance];
      if (!appearance) {
        appearance = [NSApp effectiveAppearance];
      }

      BOOL isDark = [[appearance name] rangeOfString:@"dark"
                                             options:NSCaseInsensitiveSearch].location != NSNotFound;

      // Just draw the appropriate pre-composed image - single draw operation!
      NSImage* finalComposite = isDark ? darkComposite : lightComposite;
      [finalComposite drawInRect:destRect
                        fromRect:fullRect
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0];

      return YES;
    }];

    // Explicitly mark as NOT a template image since we're handling the
    // template behavior manually. This prevents macOS from applying its own
    // template rendering on top of ours.
    [composite setTemplate:NO];

    // Replace the current image with the composite
    image_ = gfx::Image(composite);

    // Mark that this image is now a pseudo-template preserving colors
    is_pseudo_template_preserving_color_ = true;
  }
}

}  // namespace electron::api
