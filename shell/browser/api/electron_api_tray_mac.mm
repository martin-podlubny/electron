#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

#include "shell/browser/api/electron_api_tray.h"
#include "ui/gfx/image/image.h"

namespace electron::api {

// ===== Core Image Helpers =====

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
    ctx = [CIContext contextWithMTLDevice:dev options:opts];
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

// Renders a tinted version of the template, preserving 1x/2x/3x reps.
static NSImage* TintTemplate(NSImage* templateImg,
                             NSColor* tint,
                             NSSize pointSize) {
  @autoreleasepool {
    NSImage* out = [[NSImage alloc] initWithSize:pointSize];

    // If there are no reps (odd), fallback to a single focus pass.
    NSArray<NSImageRep*>* reps =
        templateImg.representations.count ? templateImg.representations : @[
          [templateImg bestRepresentationForRect:(NSRect){.size = pointSize}
                                         context:nil
                                           hints:nil]
        ];
    for (NSImageRep* rep in reps) {
      NSInteger pw = rep.pixelsWide;
      NSInteger ph = rep.pixelsHigh;
      if (pw <= 0 || ph <= 0)
        continue;

      NSBitmapImageRep* dst = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes:NULL
                        pixelsWide:pw
                        pixelsHigh:ph
                     bitsPerSample:8
                   samplesPerPixel:4
                          hasAlpha:YES
                          isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace
                       bytesPerRow:0
                      bitsPerPixel:0];

      NSGraphicsContext* ctx =
          [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
      [NSGraphicsContext saveGraphicsState];
      [NSGraphicsContext setCurrentContext:ctx];
      ctx.imageInterpolation = NSImageInterpolationHigh;

      // Fill with tint, then keep alpha from the template via DestinationIn.
      [tint setFill];
      NSRectFill(NSMakeRect(0, 0, pw, ph));
      [templateImg drawInRect:NSMakeRect(0, 0, pw, ph)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationDestinationIn
                     fraction:1.0
               respectFlipped:NO
                        hints:@{
                          NSImageHintInterpolation : @(NSImageInterpolationHigh)
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

  // Choose the richer set of reps so we don’t downsample.
  NSArray<NSImageRep*>* reps =
      colored.representations.count >= tintedTemplate.representations.count
          ? colored.representations
          : tintedTemplate.representations;

  for (NSImageRep* rep in reps) {
    NSInteger pw = rep.pixelsWide;
    NSInteger ph = rep.pixelsHigh;
    if (pw <= 0 || ph <= 0)
      continue;

    NSBitmapImageRep* dst = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pw
                      pixelsHigh:ph
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];

    NSGraphicsContext* ctx =
        [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;

    NSRect r = NSMakeRect(0, 0, pw, ph);
    [colored drawInRect:r
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:1.0
         respectFlipped:NO
                  hints:@{
                    NSImageHintInterpolation : @(NSImageInterpolationHigh)
                  }];
    [tintedTemplate
            drawInRect:r
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:NO
                 hints:@{
                   NSImageHintInterpolation : @(NSImageInterpolationHigh)
                 }];

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

    auto [coloredPart, templatePart] = DecomposeImage(source, 0.1);
    if (!coloredPart || !templatePart)
      return image;

    const size_t w = (size_t)coloredPart.size.width;
    const size_t h = (size_t)coloredPart.size.height;
    if (!w || !h)
      return image;

    const NSSize iconSize = NSMakeSize((CGFloat)w, (CGFloat)h);
    const NSRect fullRect = NSMakeRect(0, 0, (CGFloat)w, (CGFloat)h);

    NSImage* lightTemplate =
        TintTemplate(templatePart, NSColor.blackColor, iconSize);
    NSImage* darkTemplate =
        TintTemplate(templatePart, NSColor.whiteColor, iconSize);

    NSImage* lightComposite = Compose(coloredPart, lightTemplate, iconSize);
    NSImage* darkComposite = Compose(coloredPart, darkTemplate, iconSize);

    NSImage* composite = [NSImage
         imageWithSize:iconSize
               flipped:NO
        drawingHandler:^BOOL(NSRect destRect) {
          NSAppearance* ap = NSAppearance.currentDrawingAppearance
                                 ?: NSApp.effectiveAppearance;
          BOOL isDark = [[[ap name] lowercaseString] containsString:@"dark"];

          NSImage* finalImg = isDark ? darkComposite : lightComposite;
          [finalImg drawInRect:destRect
                      fromRect:fullRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0];
          return YES;
        }];

    [composite setTemplate:NO];
    return gfx::Image(composite);
  }
}

}  // namespace electron::api
