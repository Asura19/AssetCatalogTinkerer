//
//  AssetCatalogReader.m
//  Asset Catalog Tinkerer
//
//  Created by Guilherme Rambo on 27/03/16.
//  Copyright © 2016 Guilherme Rambo. All rights reserved.
//

#import "AssetCatalogReader.h"

#import "CoreUI.h"
#import "CoreUI+TV.h"

NSString * const kACSNameKey = @"name";
NSString * const kACSImageKey = @"image";
NSString * const kACSThumbnailKey = @"thumbnail";
NSString * const kACSFilenameKey = @"filename";
NSString * const kACSContentsDataKey = @"data";
NSString * const kACSImageRepKey = @"imagerep";
NSString * const kACSAssetTypeKey = @"assetType";
NSString * const kACSAssetTypeImage = @"image";
NSString * const kACSAssetTypeDocument = @"document";

NSString * const kAssetCatalogReaderErrorDomain = @"br.com.guilhermerambo.AssetCatalogReader";

@interface AssetCatalogReader ()

@property (nonatomic, copy) NSURL *fileURL;
@property (nonatomic, strong) CUICatalog *catalog;
@property (nonatomic, strong) NSMutableArray <NSDictionary <NSString *, NSObject *> *> *mutableImages;

@property (assign) NSUInteger totalNumberOfAssets;

// These properties are set when the read is initiated by a call to `resourceConstrainedReadWithMaxCount`
@property (nonatomic, assign, getter=isResourceConstrained) BOOL resourceConstrained;
@property (nonatomic, assign) int maxCount;

// Tracks filenames to avoid duplicates
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *filenameCountMap;

@end

@implementation AssetCatalogReader
{
    BOOL _computedCatalogHasRetinaContent;
    BOOL _catalogHasRetinaContent;
}

- (instancetype)initWithFileURL:(NSURL *)URL
{
    self = [super init];
    
    _ignorePackedAssets = YES;
    _fileURL = [URL copy];
    
    return self;
}

- (NSMutableArray <NSDictionary <NSString *, NSObject *> *> *)mutableImages
{
    if (!_mutableImages) _mutableImages = [NSMutableArray new];
    
    return _mutableImages;
}

- (NSMutableDictionary<NSString *, NSNumber *> *)filenameCountMap
{
    if (!_filenameCountMap) _filenameCountMap = [NSMutableDictionary new];
    
    return _filenameCountMap;
}

- (NSArray <NSDictionary <NSString *, NSObject *> *> *)images
{
    return [self.mutableImages copy];
}

- (void)cancelReading
{
    self.cancelled = true;
}

- (void)resourceConstrainedReadWithMaxCount:(int)max completionHandler:(void (^)(void))callback
{
    self.resourceConstrained = YES;
    self.maxCount = max;
    
    [self readWithCompletionHandler:callback progressHandler:nil];
}

- (void)readWithCompletionHandler:(void (^__nonnull)(void))callback progressHandler:(void (^__nullable)(double progress))progressCallback
{
    __block uint64 totalItemCount = 0;
    __block uint64 loadedItemCount = 0;
    __block uint64 maxItemCount = _maxCount;
    
    NSString *catalogPath = self.fileURL.path;
    
    if (!_resourceConstrained) {
        // we need to figure out if the user selected an app bundle or a specific .car file
        NSBundle *bundle = [NSBundle bundleWithURL:self.fileURL];
        if (!bundle) {
            catalogPath = self.fileURL.path;
            self.catalogName = catalogPath.lastPathComponent;
        } else {
            catalogPath = [bundle pathForResource:@"Assets" ofType:@"car"];
            self.catalogName = [NSString stringWithFormat:@"%@ | %@", bundle.bundlePath.lastPathComponent, catalogPath.lastPathComponent];
        }
    }

    __weak typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // bundle is nil for some reason
        if (!catalogPath) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Unable to find asset catalog path"}];
                callback();
            });
            
            return;
        }
        
        NSError *catalogError;
        self.catalog = [[CUICatalog alloc] initWithURL:[NSURL fileURLWithPath:catalogPath] error:&catalogError];
        if (catalogError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = catalogError;
                callback();
            });
            
            return;
        }
        
        if ([self isProThemeStoreAtPath:catalogPath]) {
            NSError *error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Pro asset catalogs are not supported"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = error;
                callback();
            });
            
            return;
        }
        
        if (self.distinguishCatalogsFromThemeStores) {
            if (!self.catalog.allImageNames.count || ![self.catalog respondsToSelector:@selector(imageWithName:scaleFactor:)]) {
                // CAR is a theme file not an asset catalog
                return [self readThemeStoreWithCompletionHandler:callback progressHandler:progressCallback];
            }
        } else {
            return [self readThemeStoreWithCompletionHandler:callback progressHandler:progressCallback];
        }
        
        weakSelf.totalNumberOfAssets = self.catalog.allImageNames.count;
        
        // limits the total items to be read to the total number of images or the max count set for a resource constrained read
        totalItemCount = weakSelf.resourceConstrained ? MIN(maxItemCount, weakSelf.catalog.allImageNames.count) : weakSelf.catalog.allImageNames.count;
        
        for (NSString *imageName in self.catalog.allImageNames) {
            if (weakSelf.resourceConstrained && loadedItemCount >= totalItemCount) break;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                double loadedFraction = (double)loadedItemCount / (double)totalItemCount;
                if (progressCallback) progressCallback(loadedFraction);
            });
            
            for (CUINamedImage *namedImage in [self imagesNamed:imageName]) {
                if (self.cancelled) return;
                
                @autoreleasepool {
                    if (namedImage == nil) {
                        loadedItemCount++;
                        continue;
                    }

                    // Handle CUINamedData (documents like markdown files)
                    if ([namedImage isKindOfClass:[CUINamedData class]]) {
                        NSDictionary *documentDesc = [self processNamedData:(CUINamedData *)namedImage];
                        if (documentDesc) {
                            [self.mutableImages addObject:documentDesc];
                        }
                        loadedItemCount++;
                        continue;
                    }

                    NSString *filename;
                    CGImageRef image;

                    if ([namedImage isKindOfClass:[CUINamedLayerStack class]]) {
                        CUINamedLayerStack *stack = (CUINamedLayerStack *)namedImage;
                        if (!stack.layers.count) {
                            loadedItemCount++;
                            continue;
                        }
                        
                        filename = [self makeUniqueFilename:[NSString stringWithFormat:@"%@.png", namedImage.name]];
                        image = stack.flattenedImage;
                    } else {
                        filename = [self makeUniqueFilename:[self filenameForAssetNamed:namedImage.name scale:namedImage.scale presentationState:kCoreThemeStateNone]];
                        image = namedImage.image;
                    }
                    
                    if (image == nil) {
                        loadedItemCount++;
                        continue;
                    }
                    
                    // when resource constrained and the catalog contains retina images, only load retina images
                    if ([self catalogHasRetinaContent] && weakSelf.resourceConstrained && namedImage.scale < 2) {
                        continue;
                    }

                    NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                    imageRep.size = namedImage.size;

                    NSDictionary *desc = [self imageDescriptionWithName:namedImage.name filename:filename representation:imageRep contentsData:^NSData *{
                        return [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageInterlaced:@(NO)}];
                    }];

                    if (!desc) {
                        loadedItemCount++;
                        return;
                    }
                    
                    if (self.cancelled) return;
                    
                    [self.mutableImages addObject:desc];
                    
                    if (self.cancelled) return;
                    
                    loadedItemCount++;
                }
            }
        }
        
        // we've got no images for some reason (the console will usually contain some information from CoreUI as to why)
        if (!self.images.count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Failed to load images"}];
                callback();
            });
            
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            callback();
        });
    });
}

- (void)readThemeStoreWithCompletionHandler:(void (^__nonnull)(void))callback progressHandler:(void (^__nullable)(double progress))progressCallback
{
    uint64 realTotalItemCount = [self.catalog _themeStore].themeStore.allAssetKeys.count;
    __block uint64 loadedItemCount = 0;
    
    // limits the total items to be read to the total number of images or the max count set for a resource constrained read
    __block uint64 totalItemCount = self.resourceConstrained ? MIN(_maxCount, realTotalItemCount) : realTotalItemCount;
    
    _totalNumberOfAssets = [self.catalog _themeStore].themeStore.allAssetKeys.count;

    __weak typeof(self) weakSelf = self;

    [[self.catalog _themeStore].themeStore.allAssetKeys enumerateObjectsWithOptions:0 usingBlock:^(CUIRenditionKey * _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
        if (weakSelf.resourceConstrained && loadedItemCount >= totalItemCount) return;
        
        if (self.cancelled) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            double loadedFraction = (double)loadedItemCount / (double)totalItemCount;
            if (progressCallback) progressCallback(loadedFraction);
        });
        
        @try {
            CUIThemeRendition *rendition = [[self.catalog _themeStore] renditionWithKey:key.keyList];
            // when resource constrained and the catalog contains retina images, only load retina images
            if ([self catalogHasRetinaContent] && weakSelf.resourceConstrained && rendition.scale < 2) {
                return;
            }
            
            const BOOL coreSVGPresent = CGSVGDocumentGetCanvasSize != NULL && CGContextDrawSVGDocument != NULL && CGSVGDocumentWriteToData != NULL;
            const BOOL isSVG = coreSVGPresent && rendition.isVectorBased && rendition.svgDocument;

            if (isSVG) {
                NSCustomImageRep *imageRep = [[NSCustomImageRep alloc] initWithSize:CGSVGDocumentGetCanvasSize(rendition.svgDocument) flipped:YES drawingHandler:^BOOL(NSRect dstRect) {
                    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
                    if (context && rendition.svgDocument) {
                        CGContextDrawSVGDocument(context, rendition.svgDocument);
                    }
                    return YES;
                }];
                NSString *const filename = [self makeUniqueFilename:[self filenameForVectorAssetNamed:[self cleanupRenditionName:rendition.name] renderingMode:rendition.vectorGlyphRenderingMode weight:key.themeGlyphWeight size:key.themeGlyphSize]];
                NSDictionary *desc = [self imageDescriptionWithName:rendition.name filename:filename representation:imageRep contentsData:^NSData *{
                    NSMutableData *data = [NSMutableData new];
                    CGSVGDocumentWriteToData(rendition.svgDocument, (__bridge CFMutableDataRef)data, NULL);
                    return data;
                }];
                if (self.cancelled) return;
                [self.mutableImages addObject:desc];
            } else if (rendition.unslicedImage) {
                NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:rendition.unslicedImage];
                imageRep.size = NSMakeSize(CGImageGetWidth(rendition.unslicedImage), CGImageGetHeight(rendition.unslicedImage));

                NSString *const filename = [self makeUniqueFilename:[self filenameForAssetNamed:[self cleanupRenditionName:rendition.name] scale:rendition.scale presentationState:key.themeState]];
                NSDictionary *desc = [self imageDescriptionWithName:rendition.name filename:filename representation:imageRep contentsData:^NSData *{
                    return [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageInterlaced:@(NO)}];
                }];

                BOOL ignore = [filename containsString:@"ZZPackedAsset"] && self.ignorePackedAssets;

                if (!desc || ignore) {
                    loadedItemCount++;
                    return;
                }

                if (self.cancelled) return;

                [self.mutableImages addObject:desc];
            } else if (rendition.data && rendition.data.length > 0) {
                // Handle non-image data (documents, etc.)
                NSString *extension = [self fileExtensionForData:rendition.data name:rendition.name];
                NSString *filename = [self makeUniqueFilename:[NSString stringWithFormat:@"%@.%@", [self cleanupRenditionName:rendition.name], extension]];
                
                if (self.resourceConstrained) {
                    NSDictionary *desc = @{
                        kACSNameKey: rendition.name,
                        kACSFilenameKey: filename,
                        kACSContentsDataKey: rendition.data,
                        kACSAssetTypeKey: kACSAssetTypeDocument
                    };
                    
                    if (self.cancelled) return;
                    [self.mutableImages addObject:desc];
                } else {
                    NSImage *thumbnail = [self createDocumentThumbnailForExtension:extension];
                    NSDictionary *desc = @{
                        kACSNameKey: rendition.name,
                        kACSFilenameKey: filename,
                        kACSContentsDataKey: rendition.data,
                        kACSThumbnailKey: thumbnail,
                        kACSAssetTypeKey: kACSAssetTypeDocument
                    };
                    
                    if (self.cancelled) return;
                    [self.mutableImages addObject:desc];
                }
            } else {
                NSLog(@"The rendition %@ doesn't have an image or data, It is probably an effect or material.", rendition.name);
            }

            loadedItemCount++;
        } @catch (NSException *exception) {
            NSLog(@"Exception while reading theme store: %@", exception);
        }
    }];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        callback();
    });
}

- (NSImage *)constrainImage:(NSImage *)image toSize:(NSSize)size
{
    if (image.size.width <= size.width && image.size.height <= size.height) return [image copy];
    
    CGFloat newWidth, newHeight = 0;
    double rw = image.size.width / size.width;
    double rh = image.size.height / size.height;
    
    if (rw > rh)
    {
        newHeight = MAX(roundl(image.size.height / rw), 1);
        newWidth = size.width;
    }
    else
    {
        newWidth = MAX(roundl(image.size.width / rh), 1);
        newHeight = size.height;
    }
    
    return [NSImage imageWithSize:NSMakeSize(newWidth, newHeight) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [image drawInRect:NSMakeRect(0, 0, newWidth, newHeight) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        return YES;
    }];
}

- (BOOL)isProThemeStoreAtPath:(NSString *)path
{
    #define proThemeTokenLength 18
    static const char proThemeToken[proThemeTokenLength] = { 0x50,0x72,0x6F,0x54,0x68,0x65,0x6D,0x65,0x44,0x65,0x66,0x69,0x6E,0x69,0x74,0x69,0x6F,0x6E };
    
    @try {
        NSData *catalogData = [[NSData alloc] initWithContentsOfFile:path options:NSDataReadingMappedAlways|NSDataReadingUncached error:nil];
        
        NSData *proThemeTokenData = [NSData dataWithBytes:(const void *)proThemeToken length:proThemeTokenLength];
        if ([catalogData rangeOfData:proThemeTokenData options:0 range:NSMakeRange(0, catalogData.length)].location != NSNotFound) {
            return YES;
        } else {
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Unable to determine if catalog is pro, exception: %@", exception);
        return NO;
    }
}

- (NSArray <CUINamedImage *> *)imagesNamed:(NSString *)name
{
    NSMutableArray <CUINamedImage *> *images = [[NSMutableArray alloc] initWithCapacity:3];
    
    for (NSNumber *factor in @[@1,@2,@3]) {
        CUINamedImage *image = [self.catalog imageWithName:name scaleFactor:factor.doubleValue];
        if (!image || image.scale != factor.doubleValue) continue;
        
        [images addObject:image];
    }
    
    return images;
}

- (NSDictionary *)imageDescriptionWithName:(NSString *)name filename:(NSString *)filename representation:(NSImageRep *)imageRep contentsData:(NSData *(^)(void))contentsData
{
    if (_resourceConstrained) {
        return @{
                 kACSNameKey : name,
                 kACSFilenameKey: filename,
                 kACSImageRepKey: imageRep
                 };
    } else {
        NSData *pngData = contentsData();
        if (!pngData.length) {
            NSLog(@"Unable to get PNG data from rendition named %@", name);
            return nil;
        }
        
        NSImage *originalImage = [[NSImage alloc] initWithData:pngData];
        NSImage *thumbnail = [self constrainImage:originalImage toSize:self.thumbnailSize];
        
        return @{
                 kACSNameKey : name,
                 kACSImageKey : originalImage,
                 kACSThumbnailKey: thumbnail,
                 kACSFilenameKey: filename,
                 kACSContentsDataKey: pngData
                 };
    }
}

- (NSString *)cleanupRenditionName:(NSString *)name
{
    NSArray *components = [name.stringByDeletingPathExtension componentsSeparatedByString:@"@"];
    
    return components.firstObject;
}

- (NSString *)filenameForAssetNamed:(NSString *)name scale:(CGFloat)scale presentationState:(NSInteger)presentationState
{
    if (scale > 1.0) {
        if (presentationState != kCoreThemeStateNone) {
            return [NSString stringWithFormat:@"%@_%@@%.0fx.png", name, themeStateNameForThemeState(presentationState), scale];
        } else {
            return [NSString stringWithFormat:@"%@@%.0fx.png", name, scale];
        }
    } else {
        if (presentationState != kCoreThemeStateNone) {
            return [NSString stringWithFormat:@"%@_%@.png", name, themeStateNameForThemeState(presentationState)];
        } else {
            return [NSString stringWithFormat:@"%@.png", name];
        }
    }
}

- (NSString *)filenameForVectorAssetNamed:(NSString *)name renderingMode:(UIImageSymbolRenderingMode)renderingMode weight:(UIImageSymbolWeight)weight size:(UIImageSymbolScale)size {
    NSString *weightName;
    switch (weight) {
    case UIImageSymbolWeightUnspecified:
        weightName = @"unspecified";
        break;
    case UIImageSymbolWeightUltraLight:
        weightName = @"ultraLight";
        break;
    case UIImageSymbolWeightThin:
        weightName = @"thin";
        break;
    case UIImageSymbolWeightLight:
        weightName = @"light";
        break;
    case UIImageSymbolWeightRegular:
        weightName = @"regular";
        break;
    case UIImageSymbolWeightMedium:
        weightName = @"medium";
        break;
    case UIImageSymbolWeightSemibold:
        weightName = @"semibold";
        break;
    case UIImageSymbolWeightBold:
        weightName = @"bold";
        break;
    case UIImageSymbolWeightHeavy:
        weightName = @"heavy";
        break;
    case UIImageSymbolWeightBlack:
        weightName = @"black";
        break;
    }

    NSString *sizeName;
    switch (size) {
    case UIImageSymbolScaleDefault:
        sizeName = @"default";
        break;
    case UIImageSymbolScaleUnspecified:
        sizeName = @"unspecified";
        break;
    case UIImageSymbolScaleSmall:
        sizeName = @"small";
        break;
    case UIImageSymbolScaleMedium:
        sizeName = @"medium";
        break;
    case UIImageSymbolScaleLarge:
        sizeName = @"large";
        break;
    }

    NSString *renderingModeName;
    switch (renderingMode) {
    case UIImageSymbolRenderingModeAutomatic:
        renderingModeName = @"automatic";
        break;
    case UIImageSymbolRenderingModeTemplate:
        renderingModeName = @"template";
        break;
    case UIImageSymbolRenderingModeMulticolor:
        renderingModeName = @"multicolor";
        break;
    case UIImageSymbolRenderingModeHierarchical:
        renderingModeName = @"hierarchical";
        break;
    }
    return  [NSString stringWithFormat:@"%@_%@_%@_%@.svg", name, weightName, sizeName, renderingModeName];
}

- (BOOL)catalogHasRetinaContent
{
    if (!_computedCatalogHasRetinaContent) {
        for (NSString *name in self.catalog.allImageNames) {
            for (CUINamedImage *namedImage in [self imagesNamed:name]) {
                if (namedImage.scale > 1) {
                    _catalogHasRetinaContent = YES;
                    break;
                }
            }
            if (_catalogHasRetinaContent) break;
        }
        
        _computedCatalogHasRetinaContent = YES;
    }
    
    return _catalogHasRetinaContent;
}

- (NSString *)makeUniqueFilename:(NSString *)filename
{
    // If this is the first occurrence, just use it
    NSNumber *count = self.filenameCountMap[filename];
    if (!count) {
        self.filenameCountMap[filename] = @(1);
        return filename;
    }
    
    // Extract base name and extension
    NSString *baseName = [filename stringByDeletingPathExtension];
    NSString *extension = [filename pathExtension];
    
    // Increment counter
    NSInteger currentCount = count.integerValue;
    self.filenameCountMap[filename] = @(currentCount + 1);
    
    // Generate new filename with counter
    NSString *newFilename;
    if (extension.length > 0) {
        newFilename = [NSString stringWithFormat:@"%@_%ld.%@", baseName, (long)currentCount, extension];
    } else {
        newFilename = [NSString stringWithFormat:@"%@_%ld", baseName, (long)currentCount];
    }
    
    // Recursively check if the new filename is also taken
    return [self makeUniqueFilename:newFilename];
}

- (NSDictionary *)processNamedData:(CUINamedData *)namedData
{
    if (!namedData || !namedData.data) {
        return nil;
    }
    
    NSData *data = namedData.data;
    NSString *name = namedData.name;
    
    // Determine file extension based on data content
    NSString *extension = [self fileExtensionForData:data name:name];
    NSString *filename = [self makeUniqueFilename:[NSString stringWithFormat:@"%@.%@", name, extension]];
    
    if (_resourceConstrained) {
        return @{
            kACSNameKey: name,
            kACSFilenameKey: filename,
            kACSContentsDataKey: data,
            kACSAssetTypeKey: kACSAssetTypeDocument
        };
    } else {
        // Create a placeholder thumbnail for non-image data
        NSImage *thumbnail = [self createDocumentThumbnailForExtension:extension];
        
        return @{
            kACSNameKey: name,
            kACSFilenameKey: filename,
            kACSContentsDataKey: data,
            kACSThumbnailKey: thumbnail,
            kACSAssetTypeKey: kACSAssetTypeDocument
        };
    }
}

- (NSString *)fileExtensionForData:(NSData *)data name:(NSString *)name
{
    if (!data || data.length == 0) {
        return @"bin";
    }
    
    // Check if name already has an extension
    NSString *existingExtension = [name pathExtension];
    if (existingExtension.length > 0) {
        return existingExtension;
    }
    
    // Try to detect file type from content
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger length = data.length;
    
    // Check for text-based formats
    if (length > 0) {
        // Try to decode as UTF-8 text
        NSString *textContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (textContent) {
            // Check for markdown patterns
            if ([textContent containsString:@"#"] || 
                [textContent containsString:@"##"] || 
                [textContent containsString:@"```"] ||
                ([textContent containsString:@"["] && [textContent containsString:@"]("])) {
                return @"md";
            }
            
            // Check for HTML
            if ([textContent containsString:@"<html"] || [textContent containsString:@"<!DOCTYPE"]) {
                return @"html";
            }
            
            // Check for JSON
            if ([textContent hasPrefix:@"{"] || [textContent hasPrefix:@"["]) {
                return @"json";
            }
            
            // Check for XML
            if ([textContent hasPrefix:@"<?xml"] || [textContent containsString:@"<plist"]) {
                return @"xml";
            }
            
            // Default to text
            return @"txt";
        }
    }
    
    // Check binary formats
    if (length >= 4) {
        // PNG
        if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
            return @"png";
        }
        // JPEG
        if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
            return @"jpg";
        }
        // PDF
        if (bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46) {
            return @"pdf";
        }
    }
    
    return @"bin";
}

- (NSImage *)createDocumentThumbnailForExtension:(NSString *)extension
{
    NSSize size = self.thumbnailSize.width > 0 ? self.thumbnailSize : NSMakeSize(128, 128);
    
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        // Draw background
        [[NSColor colorWithWhite:0.95 alpha:1.0] setFill];
        NSRectFill(dstRect);
        
        // Draw border
        [[NSColor colorWithWhite:0.7 alpha:1.0] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(dstRect, 1, 1)];
        [border stroke];
        
        // Draw document icon (simplified)
        CGFloat iconSize = size.width * 0.6;
        NSRect iconRect = NSMakeRect((size.width - iconSize) / 2, 
                                     (size.height - iconSize) / 2 + size.height * 0.1,
                                     iconSize, 
                                     iconSize * 0.8);
        
        [[NSColor whiteColor] setFill];
        NSBezierPath *docPath = [NSBezierPath bezierPathWithRect:iconRect];
        [docPath fill];
        
        [[NSColor colorWithWhite:0.5 alpha:1.0] setStroke];
        [docPath stroke];
        
        // Draw extension text
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:size.width * 0.15],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1.0]
        };
        
        NSString *displayText = [extension uppercaseString];
        NSSize textSize = [displayText sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint((size.width - textSize.width) / 2,
                                        (size.height - textSize.height) / 2 - size.height * 0.05);
        [displayText drawAtPoint:textPoint withAttributes:attrs];
        
        return YES;
    }];
}

@end
