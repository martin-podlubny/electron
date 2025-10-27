// Copyright (c) 2015 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "shell/common/api/electron_api_native_image.h"

#include <string>
#include <utility>
#include <vector>

#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
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
  // Note: This method is mutually exclusive with
  // SetTemplateImageWithColor. If
  // SetTemplateImageWithColor was previously called, this will
  // apply template rendering to the composite image (which is not desired).
  // Users should use one approach or the other, not both.
  [image_.AsNSImage() setTemplate:setAsTemplate];

  // Clear template-with-color state since we're using standard template mode
  if (setAsTemplate) {
    is_template_with_color_ = false;
  }
}

bool NativeImage::IsTemplateImage() {
  return [image_.AsNSImage() isTemplate];
}

bool NativeImage::IsTemplateImageWithColor() {
  return is_template_with_color_;
}

static CIContext* SharedCIContext(void) {
  static CIContext* ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    static CGColorSpaceRef kLin = NULL;
    static CGColorSpaceRef kSRGB = NULL;
    if (!kLin)
      kLin = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!kSRGB)
      kSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSDictionary* opts = @{
      kCIContextWorkingColorSpace : (__bridge id)kLin,
      kCIContextOutputColorSpace : (__bridge id)kSRGB,
      kCIContextUseSoftwareRenderer : dev ? @NO : @YES
    };
    ctx = [CIContext contextWithOptions:opts];
  });
  return ctx;
}

// Materialize CIImage to NSImage (no lazy surfaces)
static NSImage* RenderCI(CIImage* im, CGSize fallbackSize) {
  if (!im)
    return nil;
  CGRect r = im.extent;
  if (CGRectIsEmpty(r))
    r = (CGRect){.origin = CGPointZero, .size = fallbackSize};
  CGImageRef cg = [SharedCIContext() createCGImage:im fromRect:r];
  if (!cg)
    return nil;
  NSImage* ns =
      [[NSImage alloc] initWithCGImage:cg
                                  size:NSMakeSize(r.size.width, r.size.height)];
  CGImageRelease(cg);
  return ns;
}

// Build ~binary mask: 1 where gray<thr, else 0 (linear space)
static CIImage* ThresholdMask(CIImage* gray, CGFloat thr) {
  const CGFloat gain = 1000.0;

  CIFilter* mat = [CIFilter filterWithName:@"CIColorMatrix"];
  [mat setValue:gray forKey:kCIInputImageKey];
  [mat setValue:[CIVector vectorWithX:gain Y:0 Z:0 W:0] forKey:@"inputRVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:gain Z:0 W:0] forKey:@"inputGVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:gain W:0] forKey:@"inputBVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
  [mat setValue:[CIVector vectorWithX:-gain * thr
                                    Y:-gain * thr
                                    Z:-gain * thr
                                    W:0]
         forKey:@"inputBiasVector"];
  CIImage* amped = [mat outputImage];

  CIFilter* invert = [CIFilter filterWithName:@"CIColorInvert"];
  [invert setValue:amped forKey:kCIInputImageKey];
  CIImage* inv = [invert outputImage];

  CIFilter* clamp = [CIFilter filterWithName:@"CIColorClamp"];
  [clamp setValue:inv forKey:kCIInputImageKey];
  [clamp setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
           forKey:@"inputMinComponents"];
  [clamp setValue:[CIVector vectorWithX:1 Y:1 Z:1 W:1]
           forKey:@"inputMaxComponents"];
  return [clamp outputImage];
}

// Linear BT.709 luma as grayscale (alpha passthrough = 1)
static CIImage* LinearLuma(CIImage* srcLinear) {
  CIFilter* mat = [CIFilter filterWithName:@"CIColorMatrix"];
  [mat setValue:srcLinear forKey:kCIInputImageKey];
  CIVector* v = [CIVector vectorWithX:0.2126 Y:0.7152 Z:0.0722 W:0];
  [mat setValue:v forKey:@"inputRVector"];
  [mat setValue:v forKey:@"inputGVector"];
  [mat setValue:v forKey:@"inputBVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
  return [mat outputImage];
}

// Alpha channel as grayscale (RGB=alpha, A=1) to gate by alpha>0
static CIImage* AlphaAsGray(CIImage* srcLinear) {
  CIFilter* mat = [CIFilter filterWithName:@"CIColorMatrix"];
  [mat setValue:srcLinear forKey:kCIInputImageKey];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputRVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputGVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputBVector"];
  [mat setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
  return [mat outputImage];
}

// Multiply two grayscale masks using stock compositing
static CIImage* MulGray(CIImage* a, CIImage* b, CGRect extent) {
  CIFilter* mul = [CIFilter filterWithName:@"CIMultiplyCompositing"];
  [mul setValue:a forKey:kCIInputImageKey];
  [mul setValue:[b imageByCroppingToRect:extent]
         forKey:kCIInputBackgroundImageKey];
  return [[mul outputImage] imageByCroppingToRect:extent];
}

static CIImage* InvertGray(CIImage* m) {
  CIFilter* inv = [CIFilter filterWithName:@"CIColorInvert"];
  [inv setValue:m forKey:kCIInputImageKey];
  return [inv outputImage];
}

// Drop-in replacement: near-black (by linear luma) & alpha>0 → template
// (black+alpha); else → colored
static std::pair<NSImage*, NSImage*> DecomposeImage(NSImage* source,
                                                    CGFloat threshold) {
  @autoreleasepool {
    if (!source)
      return {nil, nil};

    CGImageRef cg = [source CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg)
      return {nil, nil};

    const size_t w = CGImageGetWidth(cg);
    const size_t h = CGImageGetHeight(cg);
    if (w == 0 || h == 0)
      return {nil, nil};

    const CGSize sz = CGSizeMake((CGFloat)w, (CGFloat)h);
    const CGRect extent = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    // Known input CS, then linearize for decisions
    CIImage* ci = [[CIImage alloc]
        initWithCGImage:cg
                options:@{
                  kCIImageColorSpace :
                      (__bridge id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
                }];
    CIImage* linear = [ci imageByApplyingFilter:@"CISRGBToneCurveToLinear"];

    // near-black mask (1 where luma < threshold)
    CIImage* luma = LinearLuma(linear);
    CIImage* maskL = ThresholdMask(luma, threshold);

    // alpha>0 mask
    // ThresholdMask returns 1 where value < threshold, so it gives us alpha <
    // epsilon We want the inverse: 1 where alpha >= epsilon (has alpha)
    CIImage* alphaG = AlphaAsGray(linear);
    CIImage* maskNoAlpha = ThresholdMask(alphaG, 1.0 / 255.0);
    CIImage* maskA = InvertGray(maskNoAlpha);  // Now 1 where alpha > 0

    // final mask = near-black AND alpha>0
    CIImage* finalMask = MulGray(maskL, maskA, extent);

    // template: source masked to only black pixels, then convert RGB to black
    // First, extract only the pixels where mask=1
    CIFilter* clearGen = [CIFilter filterWithName:@"CIConstantColorGenerator"];
    [clearGen setValue:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]
                forKey:@"inputColor"];
    CIImage* clear = [[clearGen outputImage] imageByCroppingToRect:extent];

    CIFilter* templMask = [CIFilter filterWithName:@"CIBlendWithMask"];
    [templMask setValue:linear forKey:kCIInputImageKey];
    [templMask setValue:clear forKey:kCIInputBackgroundImageKey];
    [templMask setValue:finalMask forKey:kCIInputMaskImageKey];
    CIImage* templMasked = [templMask outputImage];

    // Now convert RGB to black (0,0,0) while keeping alpha
    CIFilter* toBlack = [CIFilter filterWithName:@"CIColorMatrix"];
    [toBlack setValue:templMasked forKey:kCIInputImageKey];
    [toBlack setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
               forKey:@"inputRVector"];
    [toBlack setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
               forKey:@"inputGVector"];
    [toBlack setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
               forKey:@"inputBVector"];
    [toBlack setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1]
               forKey:@"inputAVector"];
    CIImage* templLinear = [[toBlack outputImage] imageByCroppingToRect:extent];

    // colored: source where NOT masked
    CIImage* invMask = InvertGray(finalMask);
    CIFilter* colorBlend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [colorBlend setValue:linear forKey:kCIInputImageKey];
    [colorBlend setValue:[CIImage imageWithColor:[CIColor colorWithRed:0
                                                                 green:0
                                                                  blue:0
                                                                 alpha:0]]
                  forKey:kCIInputBackgroundImageKey];
    [colorBlend setValue:invMask forKey:kCIInputMaskImageKey];
    CIImage* coloredLinear =
        [[colorBlend outputImage] imageByCroppingToRect:extent];

    // back to sRGB and render
    CIImage* templOut =
        [templLinear imageByApplyingFilter:@"CILinearToSRGBToneCurve"];
    CIImage* coloredOut =
        [coloredLinear imageByApplyingFilter:@"CILinearToSRGBToneCurve"];

    return {RenderCI(coloredOut, sz), RenderCI(templOut, sz)};
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
                   fromRect:NSMakeRect(0, 0, templateImg.size.width,
                                       templateImg.size.height)
                  operation:NSCompositingOperationDestinationIn
                   fraction:1.0];

    [tinted unlockFocus];
    return tinted;
  }
}

void NativeImage::SetTemplateImageWithColor(bool enable) {
  if (!enable) {
    // Revert to the original image behavior
    [image_.AsNSImage() setTemplate:NO];
    is_template_with_color_ = false;
    return;
  }

  @autoreleasepool {
    NSImage* sourceImage = image_.AsNSImage();
    if (!sourceImage) {
      return;
    }

    // Decompose the icon into colored and template parts
    // Threshold of 0.1 means pixels with RGB values < 10% are considered
    // "near-black" and will be treated as template pixels
    auto [coloredPart, templatePart] = DecomposeImage(sourceImage, 0.1);

    if (!coloredPart || !templatePart) {
      return;
    }

    // Get the original image size
    NSSize iconSize = [sourceImage size];

    // Pre-create both light and dark tinted templates
    NSImage* lightTemplate =
        TintTemplate(templatePart, [NSColor blackColor], iconSize);
    NSImage* darkTemplate =
        TintTemplate(templatePart, [NSColor whiteColor], iconSize);

    // Pre-create the final composites for both appearances
    // This avoids compositing on every draw - just one image draw per frame
    NSRect fullRect = NSMakeRect(0, 0, iconSize.width, iconSize.height);

    // Light mode composite: colored parts + black template
    NSImage* lightComposite = [[NSImage alloc] initWithSize:iconSize];
    [lightComposite lockFocus];
    [coloredPart drawInRect:fullRect
                   fromRect:NSMakeRect(0, 0, coloredPart.size.width,
                                       coloredPart.size.height)
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
                   fromRect:NSMakeRect(0, 0, coloredPart.size.width,
                                       coloredPart.size.height)
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
    [darkTemplate drawInRect:fullRect
                    fromRect:fullRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];
    [darkComposite unlockFocus];

    // Create an NSImage with a drawing handler that just picks the right
    // composite
    NSImage* composite = [NSImage
         imageWithSize:iconSize
               flipped:NO
        drawingHandler:^BOOL(NSRect destRect) {
          // Get the current drawing appearance
          NSAppearance* appearance = [NSAppearance currentDrawingAppearance];
          if (!appearance) {
            appearance = [NSApp effectiveAppearance];
          }

          BOOL isDark =
              [[appearance name] rangeOfString:@"dark"
                                       options:NSCaseInsensitiveSearch]
                  .location != NSNotFound;

          // Just draw the appropriate pre-composed image - single draw
          // operation!
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

    // Mark that this image is now a template with color
    is_template_with_color_ = true;
  }
}

}  // namespace electron::api
