#import <Cocoa/Cocoa.h>

#include "shell/browser/api/electron_api_tray.h"
#include "ui/gfx/image/image.h"

namespace electron::api {

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

    // Separate layers into template and non-template, tinting templates for
    // each mode
    NSMutableArray<NSImage*>* lightLayers = [NSMutableArray array];
    NSMutableArray<NSImage*>* darkLayers = [NSMutableArray array];

    for (const auto& [img, isTemplate] : layers) {
      NSImage* nsImg = img.AsNSImage();
      if (!nsImg)
        continue;

      if (isTemplate) {
        // Template layers: manually tint to black/white at their original size
        NSSize originalSize = nsImg.size;
        NSImage* lightVer =
            TintTemplate(nsImg, NSColor.blackColor, originalSize);
        NSImage* darkVer =
            TintTemplate(nsImg, NSColor.whiteColor, originalSize);
        [lightLayers addObject:lightVer];
        [darkLayers addObject:darkVer];
      } else {
        // Non-template layers: use as-is for both modes
        [lightLayers addObject:nsImg];
        [darkLayers addObject:nsImg];
      }
    }

    // Helper to compose layers centered at their natural size
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

    // Pre-compose light and dark versions
    NSImage* lightComposite = composeLayers(lightLayers);
    NSImage* darkComposite = composeLayers(darkLayers);

    // Create adaptive image that switches between pre-rendered versions
    NSImage* composite =
        MakeAdaptiveImage(lightComposite, darkComposite, iconSize);
    return gfx::Image(composite);
  }
}

}  // namespace electron::api
