#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

#include "shell/browser/api/electron_api_tray.h"
#include "ui/gfx/image/image.h"

namespace electron::api {

static CGColorSpaceRef SharedLinearColorSpace(void) {
  static CGColorSpaceRef cs = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
  });
  return cs;
}

static CGColorSpaceRef SharedSRGBColorSpace(void) {
  static CGColorSpaceRef cs = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  });
  return cs;
}

static CIContext* SharedCIContext(void) {
  static CIContext* ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSDictionary* opts = @{
      kCIContextWorkingColorSpace : (__bridge id)SharedLinearColorSpace(),
      kCIContextOutputColorSpace : (__bridge id)SharedSRGBColorSpace(),
      kCIContextUseSoftwareRenderer : dev ? @NO : @YES
    };
    // Use Metal if available, otherwise fall back to CPU-only context
    if (dev) {
      ctx = [CIContext contextWithMTLDevice:dev options:opts];
    } else {
      ctx = [CIContext contextWithOptions:opts];
    }
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

// Create an adaptive image that switches between light and dark versions
// based on the effective appearance of the context in which it is displayed.
static NSImage* MakeAdaptiveImage(NSImage* lightImage,
                                  NSImage* darkImage,
                                  NSSize iconSize) {
  NSImage* composite = [NSImage
       imageWithSize:iconSize
             flipped:NO
      drawingHandler:^BOOL(NSRect destRect) {
        NSAppearance* ap =
            NSAppearance.currentDrawingAppearance ?: NSApp.effectiveAppearance;
        BOOL isDark = [[[ap name] lowercaseString] containsString:@"dark"];

        NSImage* finalImg = isDark ? darkImage : lightImage;
        NSSize imgSize = finalImg.size;

        // Center the image if it's smaller than the canvas
        CGFloat x =
            destRect.origin.x + (destRect.size.width - imgSize.width) / 2.0;
        CGFloat y =
            destRect.origin.y + (destRect.size.height - imgSize.height) / 2.0;
        NSRect centeredRect = NSMakeRect(x, y, imgSize.width, imgSize.height);

        [finalImg drawInRect:centeredRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];
        return YES;
      }];

  [composite setTemplate:NO];
  return composite;
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
    CIImage* ci = [[CIImage alloc]
        initWithCGImage:cg
                options:@{
                  kCIImageColorSpace : (__bridge id)SharedSRGBColorSpace()
                }];
    CIImage* linear = [ci imageByApplyingFilter:@"CISRGBToneCurveToLinear"];

    // near-black mask (1 where luma < threshold)
    CIImage* luma = LinearLuma(linear);
    CIImage* maskL = ThresholdMask(luma, threshold);

    // alpha>0 mask: ThresholdMask gives 1 where value < threshold,
    // so first get "alpha < epsilon", then invert to get "alpha >= epsilon"
    CIImage* alphaG = AlphaAsGray(linear);
    CIImage* maskTransparent = ThresholdMask(alphaG, 1.0 / 255.0);
    CIImage* maskA = InvertGray(maskTransparent);

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

// Renders a tinted version of the template, preserving 1x/2x/3x reps.
static NSImage* TintTemplate(NSImage* templateImg,
                             NSColor* tint,
                             NSSize pointSize) {
  @autoreleasepool {
    NSImage* out = [[NSImage alloc] initWithSize:pointSize];

    // If there are no reps (odd), fallback to a single focus pass.
    // Guard against nil bestRepresentation
    NSImageRep* bestRep =
        [templateImg bestRepresentationForRect:(NSRect){.size = pointSize}
                                       context:nil
                                         hints:nil];
    NSArray<NSImageRep*>* reps = templateImg.representations.count
                                     ? templateImg.representations
                                     : (bestRep ? @[ bestRep ] : @[]);
    for (NSImageRep* rep in reps) {
      NSInteger pw = rep.pixelsWide;
      NSInteger ph = rep.pixelsHigh;
      if (pw <= 0 || ph <= 0)
        continue;

      // Use sRGB color space for consistent output with Core Image
      NSBitmapImageRep* dst = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes:NULL
                        pixelsWide:pw
                        pixelsHigh:ph
                     bitsPerSample:8
                   samplesPerPixel:4
                          hasAlpha:YES
                          isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace
                      bitmapFormat:0
                       bytesPerRow:0
                      bitsPerPixel:0];

      NSGraphicsContext* ctx =
          [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
      [NSGraphicsContext saveGraphicsState];
      [NSGraphicsContext setCurrentContext:ctx];
      // Use no interpolation for sharp menu bar icons
      ctx.imageInterpolation = NSImageInterpolationNone;

      // Fill with tint, then keep alpha from the template via DestinationIn.
      [tint setFill];
      NSRectFill(NSMakeRect(0, 0, pw, ph));
      [templateImg drawInRect:NSMakeRect(0, 0, pw, ph)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationDestinationIn
                     fraction:1.0
               respectFlipped:NO
                        hints:@{
                          NSImageHintInterpolation : @(NSImageInterpolationNone)
                        }];

      [NSGraphicsContext restoreGraphicsState];
      // Attach the rep; NSImage uses point size to map pw/ph back to 1x/2x/3x.
      [out addRepresentation:dst];
    }
    return out;
  }
}

// Precomposes colored + template per bitmap rep so the drawing handler performs
// a single image draw.
static NSImage* Compose(NSImage* colored,
                        NSImage* tintedTemplate,
                        NSSize pointSize) {
  NSImage* out = [[NSImage alloc] initWithSize:pointSize];

  // Determine scale factor for this composition
  // (assumes all reps have the same scale relationship to pointSize)
  CGFloat scaleFactor = 1.0;
  if (pointSize.width > 0) {
    // Find the largest pixel width to determine scale
    for (NSImageRep* rep in colored.representations) {
      if (rep.pixelsWide > 0) {
        CGFloat repScale = rep.pixelsWide / pointSize.width;
        if (repScale > scaleFactor) {
          scaleFactor = repScale;
        }
      }
    }
    for (NSImageRep* rep in tintedTemplate.representations) {
      if (rep.pixelsWide > 0) {
        CGFloat repScale = rep.pixelsWide / pointSize.width;
        if (repScale > scaleFactor) {
          scaleFactor = repScale;
        }
      }
    }
  }

  // Create representations at each scale factor
  NSArray<NSNumber*>* scaleFactors = @[ @1.0, @2.0, @3.0 ];
  for (NSNumber* scaleNum in scaleFactors) {
    CGFloat scale = scaleNum.doubleValue;
    NSInteger pw = (NSInteger)(pointSize.width * scale);
    NSInteger ph = (NSInteger)(pointSize.height * scale);

    if (pw <= 0 || ph <= 0)
      continue;

    // Use sRGB color space for consistent output with Core Image
    NSBitmapImageRep* dst = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pw
                      pixelsHigh:ph
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:0
                    bitsPerPixel:0];

    NSGraphicsContext* ctx =
        [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationNone;

    // Helper to draw an image centered within the canvas
    auto drawCentered = ^(NSImage* img) {
      NSSize imgSize = img.size;
      CGFloat imgW = imgSize.width * scale;
      CGFloat imgH = imgSize.height * scale;
      CGFloat x = (pw - imgW) / 2.0;
      CGFloat y = (ph - imgH) / 2.0;
      NSRect destRect = NSMakeRect(x, y, imgW, imgH);

      [img drawInRect:destRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:NO
                   hints:@{
                     NSImageHintInterpolation : @(NSImageInterpolationNone)
                   }];
    };

    // Draw both layers centered
    drawCentered(colored);
    drawCentered(tintedTemplate);

    [NSGraphicsContext restoreGraphicsState];
    [out addRepresentation:dst];
  }
  return out;
}

// Public function to apply template-with-color processing to a gfx::Image
gfx::Image ApplyTemplateImageWithColor(const gfx::Image& image) {
  @autoreleasepool {
    NSImage* source = image.AsNSImage();
    if (!source)
      return image;

    // Use the source image's point size, not pixel dimensions
    // This ensures 2x images render at the correct size
    NSSize iconSize = source.size;
    if (iconSize.width <= 0 || iconSize.height <= 0)
      return image;

    auto [coloredPart, templatePart] = DecomposeImage(source, 0.1);
    if (!coloredPart || !templatePart)
      return image;

    NSImage* lightTemplate =
        TintTemplate(templatePart, NSColor.blackColor, iconSize);
    NSImage* darkTemplate =
        TintTemplate(templatePart, NSColor.whiteColor, iconSize);

    // Template goes on bottom, colored on top (so alpha shows through)
    NSImage* lightComposite = Compose(lightTemplate, coloredPart, iconSize);
    NSImage* darkComposite = Compose(darkTemplate, coloredPart, iconSize);

    NSImage* composite =
        MakeAdaptiveImage(lightComposite, darkComposite, iconSize);
    return gfx::Image(composite);
  }
}

// Public function to compose layered tray image from separate images
gfx::Image ComposeMultiLayerTrayImage(
    const std::vector<std::pair<gfx::Image, bool>>& layers) {
  @autoreleasepool {
    if (layers.empty())
      return gfx::Image();

    // Determine the maximum size across all layers
    NSSize iconSize = NSZeroSize;
    for (const auto& [img, isTemplate] : layers) {
      NSImage* nsImg = img.AsNSImage();
      if (nsImg) {
        if (nsImg.size.width > iconSize.width)
          iconSize.width = nsImg.size.width;
        if (nsImg.size.height > iconSize.height)
          iconSize.height = nsImg.size.height;
      }
    }

    if (iconSize.width <= 0 || iconSize.height <= 0)
      return gfx::Image();

    // Pre-compose for light mode and dark mode
    // For each layer, if it's a template, tint it; otherwise use as-is
    NSMutableArray<NSImage*>* lightLayers = [NSMutableArray array];
    NSMutableArray<NSImage*>* darkLayers = [NSMutableArray array];

    for (const auto& [img, isTemplate] : layers) {
      NSImage* nsImg = img.AsNSImage();
      if (!nsImg)
        continue;

      if (isTemplate) {
        // Template layer: create separate versions for light/dark
        // Use the original image size, not the canvas size
        NSSize originalSize = nsImg.size;
        NSImage* lightVer =
            TintTemplate(nsImg, NSColor.blackColor, originalSize);
        NSImage* darkVer =
            TintTemplate(nsImg, NSColor.whiteColor, originalSize);
        [lightLayers addObject:lightVer];
        [darkLayers addObject:darkVer];
      } else {
        // Non-template layer: use same image for both modes
        [lightLayers addObject:nsImg];
        [darkLayers addObject:nsImg];
      }
    }

    // Helper to draw layers centered
    auto composeLayers = ^NSImage*(NSArray<NSImage*>* layerArray) {
      NSImage* composite = [[NSImage alloc] initWithSize:iconSize];
      [composite lockFocus];
      [[NSGraphicsContext currentContext]
          setImageInterpolation:NSImageInterpolationNone];

      for (NSImage* layer in layerArray) {
        NSSize layerSize = layer.size;
        // Center the layer if it's smaller than the canvas
        CGFloat x = (iconSize.width - layerSize.width) / 2.0;
        CGFloat y = (iconSize.height - layerSize.height) / 2.0;
        NSRect destRect = NSMakeRect(x, y, layerSize.width, layerSize.height);

        [layer drawInRect:destRect
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0
            respectFlipped:NO
                     hints:@{
                       NSImageHintInterpolation : @(NSImageInterpolationNone)
                     }];
      }

      [composite unlockFocus];
      return composite;
    };

    // Compose all layers for both light and dark modes
    NSImage* lightComposite = composeLayers(lightLayers);
    NSImage* darkComposite = composeLayers(darkLayers);

    // Create adaptive image with drawing handler
    NSImage* composite =
        MakeAdaptiveImage(lightComposite, darkComposite, iconSize);
    return gfx::Image(composite);
  }
}

// Simple appearance-based image composition
// User provides pre-rendered light and dark versions
gfx::Image ComposeAppearanceImage(const gfx::Image& lightImage,
                                  const gfx::Image& darkImage) {
  @autoreleasepool {
    NSImage* lightImg = lightImage.AsNSImage();
    NSImage* darkImg = darkImage.AsNSImage();

    if (!lightImg || !darkImg)
      return gfx::Image();

    // Use the larger of the two images' point sizes
    NSSize lightSize = lightImg.size;
    NSSize darkSize = darkImg.size;
    NSSize iconSize = NSMakeSize(std::max(lightSize.width, darkSize.width),
                                 std::max(lightSize.height, darkSize.height));

    if (iconSize.width <= 0 || iconSize.height <= 0)
      return gfx::Image();

    // Create adaptive image with drawing handler
    NSImage* composite = MakeAdaptiveImage(lightImg, darkImg, iconSize);
    return gfx::Image(composite);
  }
}

}  // namespace electron::api
