// Copyright (c) 2015 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "shell/common/api/electron_api_native_image.h"

#include <string>
#include <utility>
#include <vector>

#import <Cocoa/Cocoa.h>
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

// Helper function to decompose an image into colored and template parts.
// Decompose: near-black pixels (RGB < threshold) -> template (black+alpha);
// everything else -> colored (preserve original RGB+alpha).
// Threshold is in [0..1] (e.g. 0.1 for pixels with R,G,B < 10% brightness).
static std::pair<NSImage*, NSImage*> DecomposeImage(NSImage* source,
                                                    CGFloat threshold) {
  @autoreleasepool {
    // Get TIFF representation and create bitmap
    NSData* tiffData = [source TIFFRepresentation];
    if (!tiffData) {
      return {nil, nil};
    }

    NSBitmapImageRep* bitmap = [NSBitmapImageRep imageRepWithData:tiffData];
    if (!bitmap) {
      return {nil, nil};
    }

    NSInteger width = [bitmap pixelsWide];
    NSInteger height = [bitmap pixelsHigh];

    // Create two new bitmap reps for the decomposed parts
    NSBitmapImageRep* coloredBitmap =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                                pixelsWide:width
                                                pixelsHigh:height
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:width * 4
                                              bitsPerPixel:32];

    NSBitmapImageRep* templateBitmap =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                                pixelsWide:width
                                                pixelsHigh:height
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:width * 4
                                              bitsPerPixel:32];

    if (!coloredBitmap || !templateBitmap) {
      return {nil, nil};
    }

    // Get raw bitmap data pointers
    unsigned char* bitmapData = [bitmap bitmapData];
    unsigned char* coloredData = [coloredBitmap bitmapData];
    unsigned char* templateData = [templateBitmap bitmapData];

    if (!bitmapData || !coloredData || !templateData) {
      return {nil, nil};
    }

    NSInteger bytesPerRow = [bitmap bytesPerRow];
    NSInteger samplesPerPixel = [bitmap samplesPerPixel];

// Suppress unsafe buffer warnings for direct bitmap manipulation
// This is intentional for performance-critical pixel processing
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"

    // Process each pixel
    for (NSInteger y = 0; y < height; y++) {
      for (NSInteger x = 0; x < width; x++) {
        NSInteger pixelOffset = y * bytesPerRow + x * samplesPerPixel;

        CGFloat r = bitmapData[pixelOffset] / 255.0;
        CGFloat g = bitmapData[pixelOffset + 1] / 255.0;
        CGFloat b = bitmapData[pixelOffset + 2] / 255.0;
        CGFloat a =
            samplesPerPixel >= 4 ? bitmapData[pixelOffset + 3] / 255.0 : 1.0;

        // Check if this is a black pixel - threshold for near-black
        bool isBlack = r < threshold && g < threshold && b < threshold;

        if (isBlack && a > 0) {
          // This is a black+alpha pixel - goes to template part
          templateData[pixelOffset] = 0;
          templateData[pixelOffset + 1] = 0;
          templateData[pixelOffset + 2] = 0;
          templateData[pixelOffset + 3] = (unsigned char)(a * 255.0);

          coloredData[pixelOffset] = 0;
          coloredData[pixelOffset + 1] = 0;
          coloredData[pixelOffset + 2] = 0;
          coloredData[pixelOffset + 3] = 0;
        } else if (a > 0) {
          // This is a colored pixel - goes to colored part
          coloredData[pixelOffset] = (unsigned char)(r * 255.0);
          coloredData[pixelOffset + 1] = (unsigned char)(g * 255.0);
          coloredData[pixelOffset + 2] = (unsigned char)(b * 255.0);
          coloredData[pixelOffset + 3] = (unsigned char)(a * 255.0);

          templateData[pixelOffset] = 0;
          templateData[pixelOffset + 1] = 0;
          templateData[pixelOffset + 2] = 0;
          templateData[pixelOffset + 3] = 0;
        } else {
          // Transparent pixel
          coloredData[pixelOffset] = 0;
          coloredData[pixelOffset + 1] = 0;
          coloredData[pixelOffset + 2] = 0;
          coloredData[pixelOffset + 3] = 0;

          templateData[pixelOffset] = 0;
          templateData[pixelOffset + 1] = 0;
          templateData[pixelOffset + 2] = 0;
          templateData[pixelOffset + 3] = 0;
        }
      }
    }

#pragma clang diagnostic pop

    // Create NSImages from the bitmaps
    NSImage* coloredImage =
        [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [coloredImage addRepresentation:coloredBitmap];

    NSImage* templateImage =
        [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [templateImage addRepresentation:templateBitmap];

    return {coloredImage, templateImage};
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
