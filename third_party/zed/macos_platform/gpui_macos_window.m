#import "gpui_macos_window.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

// ============================================================================
// Captured Objective-C Models for a GPUI WYSIWYG Frame
// ============================================================================

@interface ZedCapturedMathPrimitive : NSObject
@property (nonatomic, assign) uint32_t kind;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat height;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) CGFloat lineWidth;
@property (nonatomic, assign) BOOL italic;
@property (nonatomic, assign) BOOL bold;
@property (nonatomic, assign) BOOL serif;
@property (nonatomic, copy) NSString *text;
@end

@implementation ZedCapturedMathPrimitive
@end

@interface ZedCapturedMathCanvas : NSObject
@property (nonatomic, assign) NSRange charRange;
@property (nonatomic, assign) BOOL isDisplay;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat ascent;
@property (nonatomic, assign) CGFloat descent;
@property (nonatomic, strong) NSArray<ZedCapturedMathPrimitive *> *primitives;
@end

@implementation ZedCapturedMathCanvas
@end

@interface ZedCapturedBlockDecoration : NSObject
@property (nonatomic, assign) uint32_t kind;
@property (nonatomic, assign) size_t byteStart;
@property (nonatomic, assign) size_t byteEnd;
@property (nonatomic, assign) NSRange charRange;
@property (nonatomic, assign) uint32_t level;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) CGFloat dimFactor;
@property (nonatomic, strong) NSColor *accentColor;
@property (nonatomic, copy) NSString *labelText;
@end

@implementation ZedCapturedBlockDecoration
@end

@interface ZedFenceBadgeHitTarget : NSObject
@property (nonatomic, assign) NSRect badgeRect;
@property (nonatomic, assign) size_t fenceStartByteOffset;
@property (nonatomic, copy) NSString *currentLanguage;
@end

@implementation ZedFenceBadgeHitTarget
@end

// ============================================================================
// Supported Code Fence Languages (matching main tip)
// ============================================================================

typedef struct {
    const char *canonicalId;
    const char *displayName;
} ZedFenceLanguageOption;

static const ZedFenceLanguageOption kFenceLanguageOptions[] = {
    {"swift", "Swift"},
    {"python", "Python"},
    {"javascript", "JavaScript"},
    {"typescript", "TypeScript"},
    {"rust", "Rust"},
    {"go", "Go"},
    {"c", "C"},
    {"cpp", "C++"},
    {"objc", "Objective-C"},
    {"bash", "Shell / Bash"},
    {"json", "JSON"},
    {"yaml", "YAML"},
    {"toml", "TOML"},
    {"html", "HTML / XML"},
    {"css", "CSS / SCSS"},
    {"sql", "SQL"},
    {"", "Plain Text"},
};
static const size_t kFenceLanguageOptionsCount = sizeof(kFenceLanguageOptions) / sizeof(kFenceLanguageOptions[0]);

static NSString *DisplayNameForFenceLanguage(NSString *rawLang) {
    NSString *lower = [[rawLang ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0 || [lower isEqualToString:@"text"] || [lower isEqualToString:@"plaintext"] || [lower isEqualToString:@"txt"]) {
        return @"Plain Text";
    }
    if ([lower isEqualToString:@"py"]) return @"Python";
    if ([lower isEqualToString:@"js"] || [lower isEqualToString:@"jsx"]) return @"JavaScript";
    if ([lower isEqualToString:@"ts"] || [lower isEqualToString:@"tsx"]) return @"TypeScript";
    if ([lower isEqualToString:@"rs"]) return @"Rust";
    if ([lower isEqualToString:@"golang"]) return @"Go";
    if ([lower isEqualToString:@"h"]) return @"C";
    if ([lower isEqualToString:@"c++"] || [lower isEqualToString:@"cc"] || [lower isEqualToString:@"cxx"] || [lower isEqualToString:@"hpp"]) return @"C++";
    if ([lower isEqualToString:@"objective-c"] || [lower isEqualToString:@"m"] || [lower isEqualToString:@"mm"]) return @"Objective-C";
    if ([lower isEqualToString:@"sh"] || [lower isEqualToString:@"zsh"] || [lower isEqualToString:@"shell"]) return @"Shell / Bash";
    if ([lower isEqualToString:@"yml"]) return @"YAML";
    if ([lower isEqualToString:@"xml"]) return @"HTML / XML";
    if ([lower isEqualToString:@"scss"]) return @"CSS / SCSS";
    for (size_t i = 0; i < kFenceLanguageOptionsCount; i++) {
        NSString *cid = [NSString stringWithUTF8String:kFenceLanguageOptions[i].canonicalId];
        if ([lower isEqualToString:cid]) {
            return [NSString stringWithUTF8String:kFenceLanguageOptions[i].displayName];
        }
    }
    return [rawLang uppercaseString];
}

// ============================================================================
// Helper: Draw a GPUI Math Canvas in a Flipped Context
// ============================================================================

static NSFont *ResolveMathFont(CGFloat size, BOOL italic, BOOL bold, BOOL serif) {
    if (!serif) {
        return [NSFont monospacedSystemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightRegular];
    }
    NSString *fontName = @"TimesNewRomanPSMT";
    if (bold && italic) {
        fontName = @"TimesNewRomanPS-BoldItalicMT";
    } else if (bold) {
        fontName = @"TimesNewRomanPS-BoldMT";
    } else if (italic) {
        fontName = @"TimesNewRomanPS-ItalicMT";
    }
    NSFont *f = [NSFont fontWithName:fontName size:size];
    if (!f) {
        f = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightRegular];
    }
    return f;
}

static void DrawCapturedMathCanvas(ZedCapturedMathCanvas *canvas, CGFloat originX, CGFloat baselineY, NSColor *color) {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    for (ZedCapturedMathPrimitive *prim in canvas.primitives) {
        if (prim.kind == 0) {
            if (prim.text.length == 0) continue;
            NSFont *font = ResolveMathFont(prim.fontSize, prim.italic, prim.bold, prim.serif);
            NSDictionary *attrs = @{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: color
            };
            CGFloat ascender = font.ascender;
            NSPoint pt = NSMakePoint(originX + prim.x, baselineY + prim.y - ascender);
            [prim.text drawAtPoint:pt withAttributes:attrs];
        } else if (prim.kind == 1) {
            [color setFill];
            NSRect ruleRect = NSMakeRect(originX + prim.x, baselineY + prim.y, prim.width, MAX(1.1, prim.height));
            NSRectFillUsingOperation(ruleRect, NSCompositingOperationSourceOver);
        } else if (prim.kind == 2) {
            CGFloat bottomY = baselineY + prim.y;
            CGFloat topY = bottomY - prim.height;
            CGFloat x = originX + prim.x;
            CGFloat hookW = 10.5;
            NSBezierPath *path = [NSBezierPath bezierPath];
            path.lineWidth = MAX(1.15, prim.lineWidth);
            path.lineJoinStyle = NSLineJoinStyleRound;
            path.lineCapStyle = NSLineCapStyleRound;
            [path moveToPoint:NSMakePoint(x + 0.5, topY + prim.height * 0.56)];
            [path lineToPoint:NSMakePoint(x + hookW * 0.28, topY + prim.height * 0.48)];
            [path lineToPoint:NSMakePoint(x + hookW * 0.62, bottomY - 0.5)];
            [path lineToPoint:NSMakePoint(x + hookW, topY)];
            [path lineToPoint:NSMakePoint(x + prim.width, topY)];
            [color setStroke];
            [path stroke];
        }
    }
}

// ============================================================================
// Inline Math NSTextAttachmentCell
// ============================================================================

@interface ZedGPUIMathAttachmentCell : NSTextAttachmentCell
@property (nonatomic, strong) ZedCapturedMathCanvas *canvas;
@property (nonatomic, strong) NSColor *mathColor;
@property (nonatomic, strong) NSColor *badgeBgColor;
@end

@implementation ZedGPUIMathAttachmentCell

- (NSSize)cellSize {
    return NSMakeSize(self.canvas.width + 8.0, self.canvas.ascent + self.canvas.descent + 4.0);
}

- (NSPoint)cellBaselineOffset {
    return NSMakePoint(0.0, -(self.canvas.descent + 2.0));
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    if (self.badgeBgColor) {
        NSRect pill = NSInsetRect(cellFrame, 0.5, 1.0);
        NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:4.0 yRadius:4.0];
        [self.badgeBgColor setFill];
        [bp fill];
    }
    CGFloat originX = cellFrame.origin.x + 4.0;
    CGFloat baselineY = cellFrame.origin.y + 2.0 + self.canvas.ascent;
    DrawCapturedMathCanvas(self.canvas, originX, baselineY, self.mathColor ?: [NSColor textColor]);
}

@end

// ============================================================================
// UTF-8 <-> UTF-16 Offset Conversion
// ============================================================================

static void BuildUtf8ToUtf16Table(const char *utf8, size_t utf8Len, NSUInteger *outTable) {
    NSUInteger u16 = 0;
    size_t i = 0;
    while (i < utf8Len) {
        unsigned char c = (unsigned char)utf8[i];
        size_t charBytes = 1;
        NSUInteger u16Step = 1;
        if ((c & 0x80) == 0x00) {
            charBytes = 1;
        } else if ((c & 0xE0) == 0xC0) {
            charBytes = 2;
        } else if ((c & 0xF0) == 0xE0) {
            charBytes = 3;
        } else if ((c & 0xF8) == 0xF0) {
            charBytes = 4;
            u16Step = 2;
        }
        for (size_t k = 0; k < charBytes && (i + k) <= utf8Len; k++) {
            outTable[i + k] = u16;
        }
        u16 += u16Step;
        i += charBytes;
    }
    outTable[utf8Len] = u16;
}

static size_t Utf16OffsetToUtf8Byte(const char *utf8, size_t utf8Len, NSUInteger targetUtf16) {
    NSUInteger u16 = 0;
    size_t i = 0;
    while (i < utf8Len && u16 < targetUtf16) {
        unsigned char c = (unsigned char)utf8[i];
        if ((c & 0x80) == 0x00) {
            i += 1;
            u16 += 1;
        } else if ((c & 0xE0) == 0xC0) {
            i += 2;
            u16 += 1;
        } else if ((c & 0xF0) == 0xE0) {
            i += 3;
            u16 += 1;
        } else if ((c & 0xF8) == 0xF0) {
            i += 4;
            u16 += 2;
        } else {
            i += 1;
            u16 += 1;
        }
    }
    return i > utf8Len ? utf8Len : i;
}

static NSColor *ColorFromGpuiRgba(CGpuiRgba c) {
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:c.a];
}

// ============================================================================
// Zed GPUI WYSIWYG Editor TextView
// ============================================================================

@protocol ZedEditorInteractionDelegate <NSObject>
- (BOOL)handleEditorNewline;
- (void)handleSelectCodeFenceLanguage:(NSString *)canonicalLang atFenceByteOffset:(size_t)fenceByteOffset;
@end

@interface ZedGPUIEditorTextView : NSTextView
@property (nonatomic, weak) id<ZedEditorInteractionDelegate> zedController;
@property (nonatomic, strong) NSArray<ZedCapturedBlockDecoration *> *blockDecorations;
@property (nonatomic, strong) NSArray<ZedCapturedMathCanvas *> *displayMathCanvases;
@property (nonatomic, strong) NSMutableArray<ZedFenceBadgeHitTarget *> *fenceBadgeTargets;
@property (nonatomic, strong) NSColor *headingRuleColor;
@property (nonatomic, strong) NSColor *blockquoteBarColor;
@property (nonatomic, strong) NSColor *codeBgColor;
@property (nonatomic, strong) NSColor *mathTextColor;
@property (nonatomic, strong) NSColor *secondaryTextColor;
@property (nonatomic, assign) BOOL isDarkTheme;
@end

@implementation ZedGPUIEditorTextView

- (instancetype)initWithFrame:(NSRect)frameRect textContainer:(NSTextContainer *)container {
    self = [super initWithFrame:frameRect textContainer:container];
    if (self) {
        _fenceBadgeTargets = [NSMutableArray array];
    }
    return self;
}

- (void)insertNewline:(id)sender {
    if (self.zedController && [self.zedController handleEditorNewline]) {
        return;
    }
    [super insertNewline:sender];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    for (ZedFenceBadgeHitTarget *target in self.fenceBadgeTargets) {
        if (NSPointInRect(pt, NSInsetRect(target.badgeRect, -4.0, -3.0))) {
            [self showLanguageMenuForTarget:target withEvent:event];
            return;
        }
    }
    [super mouseDown:event];
}

- (void)showLanguageMenuForTarget:(ZedFenceBadgeHitTarget *)target withEvent:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Code Fence Language"];
    NSString *currentDisplay = DisplayNameForFenceLanguage(target.currentLanguage);

    for (size_t i = 0; i < kFenceLanguageOptionsCount; i++) {
        NSString *cid = [NSString stringWithUTF8String:kFenceLanguageOptions[i].canonicalId];
        NSString *title = [NSString stringWithUTF8String:kFenceLanguageOptions[i].displayName];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(onSelectFenceLanguageMenuItem:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{
            @"lang": cid,
            @"offset": @(target.fenceStartByteOffset)
        };
        if ([title isEqualToString:currentDisplay]) {
            item.state = NSControlStateValueOn;
        }
        [menu addItem:item];
    }

    NSPoint menuOrigin = NSMakePoint(NSMinX(target.badgeRect), NSMaxY(target.badgeRect) + 2.0);
    [menu popUpMenuPositioningItem:nil atLocation:menuOrigin inView:self];
}

- (void)onSelectFenceLanguageMenuItem:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    if (![info isKindOfClass:[NSDictionary class]]) return;
    NSString *lang = info[@"lang"] ?: @"";
    size_t offset = [info[@"offset"] unsignedLongValue];
    if (self.zedController) {
        [self.zedController handleSelectCodeFenceLanguage:lang atFenceByteOffset:offset];
    }
}

- (NSRect)lineRectForCharacterRange:(NSRange)charRange {
    NSLayoutManager *lm = self.layoutManager;
    NSTextContainer *tc = self.textContainer;
    if (!lm || !tc || self.string.length == 0) return NSZeroRect;
    NSRange safe = NSIntersectionRange(charRange, NSMakeRange(0, self.string.length));
    if (safe.length == 0 && safe.location >= self.string.length) {
        safe.location = self.string.length - 1;
        safe.length = 1;
    }
    NSRange glyphRange = [lm glyphRangeForCharacterRange:safe actualCharacterRange:NULL];
    NSRect rect = [lm boundingRectForGlyphRange:glyphRange inTextContainer:tc];
    NSPoint origin = self.textContainerOrigin;
    rect.origin.x += origin.x;
    rect.origin.y += origin.y;
    return rect;
}

- (void)drawViewBackgroundInRect:(NSRect)rect {
    [super drawViewBackgroundInRect:rect];
    [self.fenceBadgeTargets removeAllObjects];

    NSPoint tcOrigin = self.textContainerOrigin;
    CGFloat contentLeft = tcOrigin.x;
    CGFloat contentWidth = self.bounds.size.width - (tcOrigin.x * 2.0);
    if (contentWidth < 120.0) contentWidth = self.bounds.size.width - 48.0;

    NSColor *borderSubtle = self.isDarkTheme
        ? [NSColor colorWithWhite:1.0 alpha:0.10]
        : [NSColor colorWithWhite:0.0 alpha:0.09];

    NSArray<ZedCapturedBlockDecoration *> *decs = self.blockDecorations;
    NSUInteger count = decs.count;
    NSUInteger idx = 0;

    while (idx < count) {
        ZedCapturedBlockDecoration *dec = decs[idx];

        // 1. Unified Contiguous Code Fence Cards (CodeFenceHeader = 2, CodeFenceRow = 3)
        if (dec.kind == 2 || dec.kind == 3) {
            ZedCapturedBlockDecoration *headerDec = (dec.kind == 2) ? dec : nil;
            NSRect unionRect = [self lineRectForCharacterRange:dec.charRange];
            NSRect headerLineRect = unionRect;

            NSUInteger nextIdx = idx + 1;
            while (nextIdx < count) {
                ZedCapturedBlockDecoration *cand = decs[nextIdx];
                if (cand.kind != 3) break;
                NSRect candRect = [self lineRectForCharacterRange:cand.charRange];
                if (!NSIsEmptyRect(candRect)) {
                    unionRect = NSIsEmptyRect(unionRect) ? candRect : NSUnionRect(unionRect, candRect);
                }
                nextIdx++;
                if (cand.level == 1) break; // is_end == true
            }

            if (!NSIsEmptyRect(unionRect)) {
                NSRect cardRect = NSMakeRect(contentLeft - 12.0, NSMinY(unionRect) - 2.0, contentWidth + 24.0, NSHeight(unionRect) + 6.0);
                NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:cardRect xRadius:8.0 yRadius:8.0];
                [(self.codeBgColor ?: [NSColor underPageBackgroundColor]) setFill];
                [cardPath fill];

                // Subtle header strip at the top of the contiguous code card
                if (!NSIsEmptyRect(headerLineRect)) {
                    CGFloat headerStripH = MAX(24.0, NSHeight(headerLineRect) + 2.0);
                    NSRect headerStrip = NSMakeRect(NSMinX(cardRect), NSMinY(cardRect), NSWidth(cardRect), MIN(headerStripH, NSHeight(cardRect)));
                    [NSGraphicsContext saveGraphicsState];
                    [cardPath addClip];
                    NSColor *stripTint = self.isDarkTheme
                        ? [NSColor colorWithWhite:1.0 alpha:0.035]
                        : [NSColor colorWithWhite:0.0 alpha:0.03];
                    [stripTint setFill];
                    NSRectFillUsingOperation(headerStrip, NSCompositingOperationSourceOver);
                    [borderSubtle setFill];
                    NSRectFillUsingOperation(NSMakeRect(NSMinX(cardRect), NSMaxY(headerStrip) - 0.5, NSWidth(cardRect), 0.5), NSCompositingOperationSourceOver);
                    [NSGraphicsContext restoreGraphicsState];
                }

                [borderSubtle setStroke];
                cardPath.lineWidth = 1.0;
                [cardPath stroke];

                // Top-right interactive Language Selector dropdown pill
                if (headerDec != nil) {
                    NSString *displayLang = DisplayNameForFenceLanguage(headerDec.labelText);
                    NSString *pillTitle = [NSString stringWithFormat:@"%@ ▾", displayLang];
                    NSFont *badgeFont = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
                    NSColor *accent = headerDec.accentColor ?: (self.secondaryTextColor ?: [NSColor secondaryLabelColor]);
                    NSDictionary *attrs = @{
                        NSFontAttributeName: badgeFont,
                        NSForegroundColorAttributeName: accent
                    };
                    NSSize sz = [pillTitle sizeWithAttributes:attrs];
                    NSRect pillRect = NSMakeRect(NSMaxX(cardRect) - sz.width - 20.0, NSMinY(cardRect) + 3.0, sz.width + 12.0, sz.height + 4.0);
                    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:5.0 yRadius:5.0];
                    [[accent colorWithAlphaComponent:0.12] setFill];
                    [pillPath fill];
                    [pillTitle drawAtPoint:NSMakePoint(pillRect.origin.x + 6.0, pillRect.origin.y + 2.0) withAttributes:attrs];

                    ZedFenceBadgeHitTarget *hit = [[ZedFenceBadgeHitTarget alloc] init];
                    hit.badgeRect = pillRect;
                    hit.fenceStartByteOffset = headerDec.byteStart;
                    hit.currentLanguage = headerDec.labelText ?: @"";
                    [self.fenceBadgeTargets addObject:hit];
                }
            }

            idx = nextIdx;
            continue;
        }

        // 2. Centered Markdown Table Block (TableRow = 6)
        if (dec.kind == 6) {
            NSMutableArray<ZedCapturedBlockDecoration *> *tableRows = [NSMutableArray arrayWithObject:dec];
            NSUInteger nextIdx = idx + 1;
            while (nextIdx < count && decs[nextIdx].kind == 6) {
                [tableRows addObject:decs[nextIdx]];
                nextIdx++;
            }

            // Compute column count and column widths across the table
            NSUInteger numCols = 0;
            NSMutableArray<NSArray<NSString *> *> *parsedRowCols = [NSMutableArray arrayWithCapacity:tableRows.count];
            for (ZedCapturedBlockDecoration *tr in tableRows) {
                NSArray<NSString *> *cols = tr.labelText.length > 0
                    ? [tr.labelText componentsSeparatedByString:@"\t"]
                    : @[];
                if (cols.count > numCols) numCols = cols.count;
                [parsedRowCols addObject:cols];
            }

            if (numCols > 0) {
                CGFloat *colWidths = (CGFloat *)calloc(numCols, sizeof(CGFloat));
                NSFont *measureFont = [NSFont systemFontOfSize:15.0 weight:NSFontWeightSemibold];
                NSDictionary *measureAttrs = @{NSFontAttributeName: measureFont};
                for (NSUInteger r = 0; r < tableRows.count; r++) {
                    ZedCapturedBlockDecoration *tr = tableRows[r];
                    if ((tr.level & 2) != 0) continue; // separator row
                    NSArray<NSString *> *cols = parsedRowCols[r];
                    for (NSUInteger c = 0; c < cols.count; c++) {
                        NSSize sz = [cols[c] sizeWithAttributes:measureAttrs];
                        CGFloat needed = ceil(sz.width) + 36.0;
                        if (needed > colWidths[c]) colWidths[c] = needed;
                    }
                }
                CGFloat totalTableWidth = 0.0;
                for (NSUInteger c = 0; c < numCols; c++) {
                    if (colWidths[c] < 96.0) colWidths[c] = 96.0;
                    totalTableWidth += colWidths[c];
                }
                if (totalTableWidth > contentWidth && totalTableWidth > 0.0) {
                    CGFloat scale = contentWidth / totalTableWidth;
                    totalTableWidth = 0.0;
                    for (NSUInteger c = 0; c < numCols; c++) {
                        colWidths[c] = floor(colWidths[c] * scale);
                        totalTableWidth += colWidths[c];
                    }
                }
                CGFloat tableLeft = contentLeft + MAX(0.0, floor((contentWidth - totalTableWidth) * 0.5));

                NSRect tableUnion = NSZeroRect;
                for (ZedCapturedBlockDecoration *tr in tableRows) {
                    NSRect rr = [self lineRectForCharacterRange:tr.charRange];
                    if (!NSIsEmptyRect(rr)) {
                        tableUnion = NSIsEmptyRect(tableUnion) ? rr : NSUnionRect(tableUnion, rr);
                    }
                }

                if (!NSIsEmptyRect(tableUnion)) {
                    NSRect tableCard = NSMakeRect(tableLeft, NSMinY(tableUnion) - 2.0, totalTableWidth, NSHeight(tableUnion) + 4.0);
                    NSBezierPath *tablePath = [NSBezierPath bezierPathWithRoundedRect:tableCard xRadius:6.0 yRadius:6.0];

                    // Subtle card background
                    [[(self.codeBgColor ?: [NSColor controlBackgroundColor]) colorWithAlphaComponent:0.35] setFill];
                    [tablePath fill];

                    [NSGraphicsContext saveGraphicsState];
                    [tablePath addClip];

                    for (NSUInteger r = 0; r < tableRows.count; r++) {
                        ZedCapturedBlockDecoration *tr = tableRows[r];
                        NSRect rr = [self lineRectForCharacterRange:tr.charRange];
                        if (NSIsEmptyRect(rr)) continue;
                        BOOL isHeader = (tr.level & 1) != 0;
                        BOOL isSep = (tr.level & 2) != 0;

                        if (isHeader) {
                            NSRect hdrRect = NSMakeRect(tableLeft, NSMinY(rr) - 2.0, totalTableWidth, NSHeight(rr) + 2.0);
                            [[(self.codeBgColor ?: [NSColor separatorColor]) colorWithAlphaComponent:0.75] setFill];
                            NSRectFillUsingOperation(hdrRect, NSCompositingOperationSourceOver);
                        } else if (isSep) {
                            CGFloat sepY = NSMidY(rr);
                            [borderSubtle setFill];
                            NSRectFillUsingOperation(NSMakeRect(tableLeft, sepY - 0.75, totalTableWidth, 1.5), NSCompositingOperationSourceOver);
                        } else if (r > 0) {
                            [borderSubtle setFill];
                            NSRectFillUsingOperation(NSMakeRect(tableLeft, NSMinY(rr), totalTableWidth, 0.75), NSCompositingOperationSourceOver);
                        }
                    }

                    // Draw vertical column dividers
                    CGFloat colX = tableLeft;
                    [borderSubtle setFill];
                    for (NSUInteger c = 0; c + 1 < numCols; c++) {
                        colX += colWidths[c];
                        NSRectFillUsingOperation(NSMakeRect(colX, NSMinY(tableCard), 0.75, NSHeight(tableCard)), NSCompositingOperationSourceOver);
                    }

                    [NSGraphicsContext restoreGraphicsState];

                    [borderSubtle setStroke];
                    tablePath.lineWidth = 1.0;
                    [tablePath stroke];
                }

                free(colWidths);
            }

            idx = nextIdx;
            continue;
        }

        // 3. InlineCodePill (kind == 7): Rounded pill background + subtle border
        if (dec.kind == 7) {
            NSRect spanRect = [self lineRectForCharacterRange:dec.charRange];
            if (!NSIsEmptyRect(spanRect)) {
                NSRect pillRect = NSInsetRect(spanRect, -3.5, 1.0);
                NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:4.0 yRadius:4.0];
                [(self.codeBgColor ?: [NSColor underPageBackgroundColor]) setFill];
                [pillPath fill];
                [borderSubtle setStroke];
                pillPath.lineWidth = 0.75;
                [pillPath stroke];
            }
            idx++;
            continue;
        }

        // 4. Other single-line block decorations (HeadingRule = 0, BlockquoteBar = 1, HorizontalRule = 5)
        NSRect blockRect = [self lineRectForCharacterRange:dec.charRange];
        if (!NSIsEmptyRect(blockRect)) {
            if (dec.kind == 0) {
                NSRect rule = NSMakeRect(contentLeft, NSMaxY(blockRect) - 3.0, contentWidth, 1.0);
                [(self.headingRuleColor ?: [NSColor separatorColor]) setFill];
                NSRectFillUsingOperation(rule, NSCompositingOperationSourceOver);
            } else if (dec.kind == 1) {
                NSColor *barColor = self.blockquoteBarColor ?: [NSColor secondaryLabelColor];
                [barColor setFill];
                for (uint32_t n = 0; n < MAX(1u, dec.level); n++) {
                    NSRect bar = NSMakeRect(contentLeft + (CGFloat)n * 12.0, NSMinY(blockRect) + 2.0, 3.0, NSHeight(blockRect) - 4.0);
                    NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5];
                    [bp fill];
                }
            } else if (dec.kind == 5 && !dec.isActive) {
                CGFloat midY = NSMidY(blockRect);
                NSRect hr = NSMakeRect(contentLeft, midY, contentWidth, 1.5);
                [(self.headingRuleColor ?: [NSColor separatorColor]) setFill];
                NSRectFillUsingOperation(hr, NSCompositingOperationSourceOver);
            }
        }

        idx++;
    }

    // 5. Draw GPUI Display Math Cards ($$...$$) from frame.display_math_canvases
    for (ZedCapturedMathCanvas *canvas in self.displayMathCanvases) {
        NSRect blockRect = [self lineRectForCharacterRange:canvas.charRange];
        if (NSIsEmptyRect(blockRect)) continue;

        CGFloat cardHeight = MAX(NSHeight(blockRect) - 4.0, canvas.ascent + canvas.descent + 20.0);
        NSRect cardRect = NSMakeRect(contentLeft - 8.0, NSMinY(blockRect) + 2.0, contentWidth + 16.0, cardHeight);

        NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:cardRect xRadius:8.0 yRadius:8.0];
        [(self.codeBgColor ?: [NSColor controlBackgroundColor]) setFill];
        [cardPath fill];

        [borderSubtle setStroke];
        cardPath.lineWidth = 1.0;
        [cardPath stroke];

        CGFloat totalMathH = canvas.ascent + canvas.descent;
        CGFloat topPad = (NSHeight(cardRect) - totalMathH) * 0.5;
        CGFloat baselineY = NSMinY(cardRect) + topPad + canvas.ascent;
        CGFloat originX = NSMinX(cardRect) + MAX(16.0, (NSWidth(cardRect) - canvas.width) * 0.5);

        DrawCapturedMathCanvas(canvas, originX, baselineY, self.mathTextColor ?: [NSColor textColor]);
    }
}

@end

// ============================================================================
// Zed WYSIWYG Editor Window Controller (Pure Editor View, Respecting Zed Mode)
// ============================================================================

@interface ZedWindowController : NSObject <NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate, ZedEditorInteractionDelegate>
@property (nonatomic, assign) void *rustUserData;
@property (nonatomic, assign) CGpuiEvaluateFn evaluateFn;
@property (nonatomic, assign) CGpuiNewlineFn newlineFn;
@property (nonatomic, assign) CGpuiSetFenceLangFn setFenceLangFn;
@property (nonatomic, assign) CGpuiFreeStringFn freeStringFn;

@property (nonatomic, copy) NSString *initialText;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSScrollView *editorScrollView;
@property (nonatomic, strong) ZedGPUIEditorTextView *editorView;

@property (nonatomic, assign) BOOL hasAppearanceOverride;
@property (nonatomic, assign) BOOL appearanceOverrideIsDark;
@property (nonatomic, assign) BOOL isApplyingAttributes;
@property (nonatomic, assign) NSInteger lastCursorLine;
@property (nonatomic, assign) NSRange lastSelectionRange;
@end

static void RenderFrameBridgeCallback(void *cb_ctx, const CGpuiRenderFrame *frame);

@implementation ZedWindowController

- (instancetype)initWithInitialText:(NSString *)initialText {
    self = [super init];
    if (self) {
        _initialText = [initialText copy] ?: @"# OpenType in Zed\n";
        _hasAppearanceOverride = NO;
        _appearanceOverrideIsDark = YES;
        _lastCursorLine = -1;
        _lastSelectionRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (BOOL)effectiveZedIsDark {
    if (self.hasAppearanceOverride) {
        return self.appearanceOverrideIsDark;
    }
    NSAppearance *app = self.window.effectiveAppearance ?: [NSApp effectiveAppearance];
    if (!app) return YES;
    NSAppearanceName matched = [app bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua
    ]];
    return [matched isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // App Menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Zed"];
    [appMenu addItemWithTitle:@"About Zed" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Zed" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];

    // Edit Menu
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:NSSelectorFromString(@"redo:") keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu];

    // View Menu (Toggle Zed Dark / Light Appearance to verify Zed mode sync)
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *toggleAppearanceItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Dark / Light Appearance" action:@selector(toggleZedAppearanceMode:) keyEquivalent:@"l"];
    toggleAppearanceItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    toggleAppearanceItem.target = self;
    [viewMenu addItem:toggleAppearanceItem];
    [viewItem setSubmenu:viewMenu];

    [NSApp setMainMenu:mainMenu];
}

- (void)toggleZedAppearanceMode:(id)sender {
    BOOL currentlyDark = [self effectiveZedIsDark];
    self.hasAppearanceOverride = YES;
    self.appearanceOverrideIsDark = !currentlyDark;
    self.window.appearance = [NSAppearance appearanceNamed:self.appearanceOverrideIsDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [self refreshFromRustEngine:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setupMenuBar];
    [self buildWindow];
    [self refreshFromRustEngine:YES];

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.editorView];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)windowDidResize:(NSNotification *)notification {
    [self refreshFromRustEngine:YES];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 1020, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"OpenType_in_Zed.md — Zed";
    self.window.minSize = NSMakeSize(640, 440);
    self.window.delegate = self;
    [self.window center];

    NSView *root = self.window.contentView;
    root.wantsLayer = YES;

    // Pure Zed Editor ScrollView + ZedGPUIEditorTextView (no usurped tab bars or sidebars)
    self.editorScrollView = [[NSScrollView alloc] initWithFrame:root.bounds];
    self.editorScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.editorScrollView.hasVerticalScroller = YES;
    self.editorScrollView.drawsBackground = YES;
    self.editorScrollView.borderType = NSNoBorder;

    NSSize contentSize = self.editorScrollView.contentSize;
    NSTextStorage *textStorage = [[NSTextStorage alloc] init];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    [textStorage addLayoutManager:layoutManager];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(contentSize.width, CGFLOAT_MAX)];
    textContainer.widthTracksTextView = YES;
    [layoutManager addTextContainer:textContainer];

    self.editorView = [[ZedGPUIEditorTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height) textContainer:textContainer];
    self.editorView.zedController = self;
    self.editorView.minSize = NSMakeSize(0.0, contentSize.height);
    self.editorView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.editorView.verticallyResizable = YES;
    self.editorView.horizontallyResizable = NO;
    self.editorView.autoresizingMask = NSViewWidthSizable;
    self.editorView.richText = NO;
    self.editorView.importsGraphics = NO;
    self.editorView.allowsUndo = YES;
    self.editorView.automaticQuoteSubstitutionEnabled = NO;
    self.editorView.automaticDashSubstitutionEnabled = NO;
    self.editorView.automaticTextReplacementEnabled = NO;
    self.editorView.textContainerInset = NSMakeSize(56.0, 36.0);
    self.editorView.delegate = self;

    self.isApplyingAttributes = YES;
    self.editorView.string = self.initialText;
    NSUInteger endLoc = self.editorView.string.length;
    [self.editorView setSelectedRange:NSMakeRange(endLoc, 0)];
    self.isApplyingAttributes = NO;

    self.editorScrollView.documentView = self.editorView;
    [root addSubview:self.editorScrollView];
}

// ============================================================================
// Editor Interaction Callbacks (Newline Continuation & Fence Language Selector)
// ============================================================================

- (BOOL)handleEditorNewline {
    if (!self.newlineFn || !self.freeStringFn) return NO;
    NSRange sel = self.editorView.selectedRange;
    if (sel.length > 0) return NO;

    NSString *text = self.editorView.string ?: @"";
    const char *utf8 = [text UTF8String];
    if (!utf8) return NO;
    size_t utf8Len = strlen(utf8);
    size_t cursorByte = Utf16OffsetToUtf8Byte(utf8, utf8Len, sel.location);

    size_t newCursorByte = cursorByte;
    char *updatedUtf8 = self.newlineFn(self.rustUserData, utf8, cursorByte, &newCursorByte);
    if (!updatedUtf8) return NO;

    NSString *updatedStr = [NSString stringWithUTF8String:updatedUtf8];
    size_t newUtf8Len = strlen(updatedUtf8);
    NSUInteger *byteToU16 = (NSUInteger *)calloc(newUtf8Len + 1, sizeof(NSUInteger));
    BuildUtf8ToUtf16Table(updatedUtf8, newUtf8Len, byteToU16);
    NSUInteger newU16Cursor = byteToU16[MIN(newCursorByte, newUtf8Len)];
    free(byteToU16);
    self.freeStringFn(updatedUtf8);

    if (!updatedStr) return NO;

    self.isApplyingAttributes = YES;
    [self.editorView.textStorage replaceCharactersInRange:NSMakeRange(0, text.length) withString:updatedStr];
    [self.editorView setSelectedRange:NSMakeRange(MIN(newU16Cursor, updatedStr.length), 0)];
    self.isApplyingAttributes = NO;

    [self refreshFromRustEngine:YES];
    return YES;
}

- (void)handleSelectCodeFenceLanguage:(NSString *)canonicalLang atFenceByteOffset:(size_t)fenceByteOffset {
    if (!self.setFenceLangFn || !self.freeStringFn) return;
    NSString *text = self.editorView.string ?: @"";
    const char *utf8 = [text UTF8String];
    const char *langUtf8 = [canonicalLang UTF8String];
    if (!utf8 || !langUtf8) return;

    char *updatedUtf8 = self.setFenceLangFn(self.rustUserData, utf8, fenceByteOffset, langUtf8);
    if (!updatedUtf8) return;

    NSString *updatedStr = [NSString stringWithUTF8String:updatedUtf8];
    self.freeStringFn(updatedUtf8);
    if (!updatedStr) return;

    NSRange savedSel = self.editorView.selectedRange;
    self.isApplyingAttributes = YES;
    [self.editorView.textStorage replaceCharactersInRange:NSMakeRange(0, text.length) withString:updatedStr];
    NSUInteger clampedLoc = MIN(savedSel.location, updatedStr.length);
    [self.editorView setSelectedRange:NSMakeRange(clampedLoc, 0)];
    self.isApplyingAttributes = NO;

    [self refreshFromRustEngine:YES];
}

// ============================================================================
// NSTextViewDelegate Hooks
// ============================================================================

- (void)textDidChange:(NSNotification *)notification {
    if (self.isApplyingAttributes) return;
    [self refreshFromRustEngine:YES];
}

- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (self.isApplyingAttributes) return;
    NSRange sel = self.editorView.selectedRange;
    NSString *str = self.editorView.string ?: @"";
    NSUInteger safeLoc = MIN(sel.location, str.length);
    NSInteger lineNum = 1;
    for (NSUInteger i = 0; i < safeLoc; i++) {
        if ([str characterAtIndex:i] == '\n') lineNum++;
    }
    BOOL lineChanged = (lineNum != self.lastCursorLine);
    BOOL selLenChanged = (sel.length != self.lastSelectionRange.length);
    self.lastCursorLine = lineNum;
    self.lastSelectionRange = sel;
    if (lineChanged || selLenChanged) {
        [self refreshFromRustEngine:YES];
    }
}

// ============================================================================
// Core Rust -> AppKit/GPUI Render Pipeline
// ============================================================================

- (void)refreshFromRustEngine:(BOOL)restyleText {
    if (!self.evaluateFn || !self.editorView) return;
    NSString *text = self.editorView.string ?: @"";
    const char *utf8 = [text UTF8String];
    if (!utf8) utf8 = "";
    size_t utf8Len = strlen(utf8);

    NSRange sel = self.editorView.selectedRange;
    size_t selStartByte = Utf16OffsetToUtf8Byte(utf8, utf8Len, MIN(sel.location, text.length));
    size_t selEndByte = Utf16OffsetToUtf8Byte(utf8, utf8Len, MIN(NSMaxRange(sel), text.length));
    BOOL isDark = [self effectiveZedIsDark];

    self.evaluateFn(
        self.rustUserData,
        utf8,
        selStartByte,
        selEndByte,
        isDark,
        RenderFrameBridgeCallback,
        (__bridge void *)self
    );
}

- (void)applyRustRenderFrame:(const CGpuiRenderFrame *)frame {
    NSString *text = self.editorView.string ?: @"";
    const char *utf8 = [text UTF8String];
    if (!utf8) utf8 = "";
    size_t utf8Len = strlen(utf8);

    NSUInteger *byteToU16 = (NSUInteger *)calloc(utf8Len + 1, sizeof(NSUInteger));
    BuildUtf8ToUtf16Table(utf8, utf8Len, byteToU16);

    // 1. Apply Zed Appearance Palette (Dark / Light)
    NSColor *editorBg = ColorFromGpuiRgba(frame->theme.editor_bg);
    NSColor *textFg = ColorFromGpuiRgba(frame->theme.text_fg);
    NSColor *headingFg = ColorFromGpuiRgba(frame->theme.heading_fg);
    NSColor *secondaryFg = ColorFromGpuiRgba(frame->theme.secondary_fg);
    NSColor *linkFg = ColorFromGpuiRgba(frame->theme.link_fg);
    NSColor *codeBg = ColorFromGpuiRgba(frame->theme.code_bg);
    NSColor *inlineCodeFg = ColorFromGpuiRgba(frame->theme.inline_code_fg);
    BOOL isDark = frame->theme.is_dark;
    CGFloat baseFontSize = MAX(14.0, frame->theme.base_font_size);

    self.editorScrollView.backgroundColor = editorBg;
    self.editorView.backgroundColor = editorBg;
    self.editorView.insertionPointColor = linkFg;
    self.editorView.isDarkTheme = isDark;
    self.editorView.headingRuleColor = [secondaryFg colorWithAlphaComponent:0.25];
    self.editorView.blockquoteBarColor = [linkFg colorWithAlphaComponent:0.65];
    self.editorView.codeBgColor = codeBg;
    self.editorView.mathTextColor = headingFg;
    self.editorView.secondaryTextColor = secondaryFg;

    // 2. Capture Block Decorations & Math Canvases (converting UTF-8 byte ranges -> UTF-16 NSRange)
    NSMutableArray<ZedCapturedBlockDecoration *> *capturedBlocks = [NSMutableArray arrayWithCapacity:frame->blocks_len];
    for (size_t i = 0; i < frame->blocks_len; i++) {
        const CGpuiBlockDecoration *b = &frame->blocks[i];
        size_t s = MIN(b->byte_start, utf8Len);
        size_t e = MIN(MAX(s, b->byte_end), utf8Len);
        NSUInteger uStart = byteToU16[s];
        NSUInteger uEnd = byteToU16[e];
        ZedCapturedBlockDecoration *dec = [[ZedCapturedBlockDecoration alloc] init];
        dec.kind = b->kind;
        dec.byteStart = s;
        dec.byteEnd = e;
        dec.charRange = NSMakeRange(uStart, uEnd - uStart);
        dec.level = b->level;
        dec.isActive = b->is_active;
        dec.dimFactor = b->dim_factor;
        dec.accentColor = ColorFromGpuiRgba(b->accent_rgba);
        dec.labelText = b->label_text ? [NSString stringWithUTF8String:b->label_text] : @"";
        [capturedBlocks addObject:dec];
    }
    self.editorView.blockDecorations = capturedBlocks;

    NSMutableArray<ZedCapturedMathCanvas *> *displayCanvases = [NSMutableArray array];
    NSMutableArray<ZedCapturedMathCanvas *> *inlineCanvases = [NSMutableArray array];

    for (size_t i = 0; i < frame->math_canvases_len; i++) {
        const CGpuiMathCanvas *mc = &frame->math_canvases[i];
        size_t s = MIN(mc->byte_start, utf8Len);
        size_t e = MIN(MAX(s, mc->byte_end), utf8Len);
        NSUInteger uStart = byteToU16[s];
        NSUInteger uEnd = byteToU16[e];
        if (uEnd <= uStart) continue;

        ZedCapturedMathCanvas *cap = [[ZedCapturedMathCanvas alloc] init];
        cap.charRange = NSMakeRange(uStart, uEnd - uStart);
        cap.isDisplay = mc->is_display;
        cap.width = mc->width;
        cap.ascent = mc->ascent;
        cap.descent = mc->descent;

        NSMutableArray<ZedCapturedMathPrimitive *> *prims = [NSMutableArray arrayWithCapacity:mc->primitives_len];
        for (size_t p = 0; p < mc->primitives_len; p++) {
            const CGpuiMathPrimitive *mp = &mc->primitives[p];
            ZedCapturedMathPrimitive *cp = [[ZedCapturedMathPrimitive alloc] init];
            cp.kind = mp->kind;
            cp.x = mp->x;
            cp.y = mp->y;
            cp.width = mp->width;
            cp.height = mp->height;
            cp.fontSize = mp->font_size;
            cp.lineWidth = mp->line_width;
            cp.italic = mp->italic;
            cp.bold = mp->bold;
            cp.serif = mp->serif;
            cp.text = mp->text ? [NSString stringWithUTF8String:mp->text] : @"";
            [prims addObject:cp];
        }
        cap.primitives = prims;
        if (cap.isDisplay) {
            [displayCanvases addObject:cap];
        } else {
            [inlineCanvases addObject:cap];
        }
    }
    self.editorView.displayMathCanvases = displayCanvases;

    // 3. Apply Live Typography & DisplayMap Syntax Folds to NSTextStorage
    NSTextStorage *ts = self.editorView.textStorage;
    NSRange fullRange = NSMakeRange(0, ts.length);
    if (fullRange.length > 0) {
        self.isApplyingAttributes = YES;
        NSRange savedSel = self.editorView.selectedRange;
        NSRange activeLineRange = [text lineRangeForRange:NSMakeRange(MIN(savedSel.location, text.length), 0)];
        [ts beginEditing];

        NSFont *bodyFont = [NSFont systemFontOfSize:baseFontSize weight:NSFontWeightRegular];
        NSFont *monoFont = [NSFont monospacedSystemFontOfSize:baseFontSize - 1.5 weight:NSFontWeightRegular];
        NSFont *collapsedFont = [NSFont systemFontOfSize:0.01];

        NSMutableParagraphStyle *basePara = [[NSMutableParagraphStyle alloc] init];
        basePara.lineSpacing = 5.0;
        basePara.paragraphSpacing = 6.0;

        [ts removeAttribute:NSAttachmentAttributeName range:fullRange];
        [ts removeAttribute:NSBackgroundColorAttributeName range:fullRange];
        [ts removeAttribute:NSKernAttributeName range:fullRange];
        [ts removeAttribute:NSBaselineOffsetAttributeName range:fullRange];
        [ts addAttributes:@{
            NSFontAttributeName: bodyFont,
            NSForegroundColorAttributeName: textFg,
            NSParagraphStyleAttributeName: basePara
        } range:fullRange];

        // Style Headings (# .. ######)
        NSRegularExpression *headingRx = [NSRegularExpression regularExpressionWithPattern:@"^(#{1,6})\\s+(.+)$" options:NSRegularExpressionAnchorsMatchLines error:nil];
        [headingRx enumerateMatchesInString:text options:0 range:fullRange usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            NSRange hashesRange = [match rangeAtIndex:1];
            NSRange fullMatch = match.range;
            NSUInteger level = hashesRange.length;
            CGFloat scale = (level == 1) ? 1.75 : (level == 2) ? 1.42 : (level == 3) ? 1.20 : 1.08;
            NSFont *hFont = [NSFont systemFontOfSize:round(baseFontSize * scale) weight:NSFontWeightBold];
            [ts addAttributes:@{
                NSFontAttributeName: hFont,
                NSForegroundColorAttributeName: headingFg
            } range:fullMatch];
            [ts addAttribute:NSForegroundColorAttributeName value:secondaryFg range:hashesRange];
        }];

        // Style Bold (**text**)
        NSRegularExpression *boldRx = [NSRegularExpression regularExpressionWithPattern:@"(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1" options:0 error:nil];
        NSFont *boldFont = [NSFont systemFontOfSize:baseFontSize weight:NSFontWeightBold];
        [boldRx enumerateMatchesInString:text options:0 range:fullRange usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            [ts addAttribute:NSFontAttributeName value:boldFont range:[match rangeAtIndex:2]];
            [ts addAttribute:NSForegroundColorAttributeName value:secondaryFg range:[match rangeAtIndex:1]];
        }];

        // Style Inline Code (`code`) — rounded background pill is drawn in drawViewBackgroundInRect
        NSRegularExpression *codeRx = [NSRegularExpression regularExpressionWithPattern:@"(`+)([^`\\n]+?)\\1" options:0 error:nil];
        [codeRx enumerateMatchesInString:text options:0 range:fullRange usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            [ts addAttributes:@{
                NSFontAttributeName: monoFont,
                NSForegroundColorAttributeName: inlineCodeFg
            } range:match.range];
        }];

        // Style Blockquotes, Contiguous Code Fences, and Display Math from captured blocks
        NSMutableParagraphStyle *codeFencePara = [[NSMutableParagraphStyle alloc] init];
        codeFencePara.lineSpacing = 2.0;
        codeFencePara.paragraphSpacing = 0.0;
        codeFencePara.paragraphSpacingBefore = 0.0;

        for (ZedCapturedBlockDecoration *dec in capturedBlocks) {
            NSRange r = NSIntersectionRange(dec.charRange, fullRange);
            if (r.length == 0) continue;
            if (dec.kind == 1) {
                NSMutableParagraphStyle *bqPara = [basePara mutableCopy];
                CGFloat indent = (CGFloat)MAX(1u, dec.level) * 16.0;
                bqPara.headIndent = indent;
                bqPara.firstLineHeadIndent = indent;
                [ts addAttributes:@{
                    NSParagraphStyleAttributeName: bqPara,
                    NSForegroundColorAttributeName: secondaryFg
                } range:r];
            } else if (dec.kind == 2 || dec.kind == 3) {
                [ts addAttributes:@{
                    NSFontAttributeName: monoFont,
                    NSForegroundColorAttributeName: (dec.kind == 2) ? secondaryFg : textFg,
                    NSParagraphStyleAttributeName: codeFencePara
                } range:r];
            } else if (dec.kind == 4) {
                if (dec.isActive) {
                    [ts addAttributes:@{
                        NSFontAttributeName: monoFont,
                        NSForegroundColorAttributeName: inlineCodeFg,
                        NSBackgroundColorAttributeName: [codeBg colorWithAlphaComponent:0.55]
                    } range:r];
                } else {
                    [ts addAttributes:@{
                        NSFontAttributeName: monoFont,
                        NSForegroundColorAttributeName: [NSColor clearColor]
                    } range:r];
                }
            }
        }

        // Style Centered Markdown Tables (kind == 6)
        CGFloat contentWidth = self.editorView.bounds.size.width - (self.editorView.textContainerOrigin.x * 2.0);
        if (contentWidth < 120.0) contentWidth = 760.0;

        NSUInteger bIdx = 0;
        while (bIdx < capturedBlocks.count) {
            if (capturedBlocks[bIdx].kind != 6) {
                bIdx++;
                continue;
            }
            NSMutableArray<ZedCapturedBlockDecoration *> *tableRows = [NSMutableArray arrayWithObject:capturedBlocks[bIdx]];
            NSUInteger nextIdx = bIdx + 1;
            while (nextIdx < capturedBlocks.count && capturedBlocks[nextIdx].kind == 6) {
                [tableRows addObject:capturedBlocks[nextIdx]];
                nextIdx++;
            }

            NSUInteger numCols = 0;
            NSMutableArray<NSArray<NSString *> *> *parsedRowCols = [NSMutableArray arrayWithCapacity:tableRows.count];
            for (ZedCapturedBlockDecoration *tr in tableRows) {
                NSArray<NSString *> *cols = tr.labelText.length > 0
                    ? [tr.labelText componentsSeparatedByString:@"\t"]
                    : @[];
                if (cols.count > numCols) numCols = cols.count;
                [parsedRowCols addObject:cols];
            }

            if (numCols > 0) {
                CGFloat *colWidths = (CGFloat *)calloc(numCols, sizeof(CGFloat));
                NSFont *measureFont = [NSFont systemFontOfSize:15.0 weight:NSFontWeightSemibold];
                NSDictionary *measureAttrs = @{NSFontAttributeName: measureFont};
                for (NSUInteger r = 0; r < tableRows.count; r++) {
                    ZedCapturedBlockDecoration *tr = tableRows[r];
                    if ((tr.level & 2) != 0) continue;
                    NSArray<NSString *> *cols = parsedRowCols[r];
                    for (NSUInteger c = 0; c < cols.count; c++) {
                        NSSize sz = [cols[c] sizeWithAttributes:measureAttrs];
                        CGFloat needed = ceil(sz.width) + 36.0;
                        if (needed > colWidths[c]) colWidths[c] = needed;
                    }
                }
                CGFloat totalTableWidth = 0.0;
                for (NSUInteger c = 0; c < numCols; c++) {
                    if (colWidths[c] < 96.0) colWidths[c] = 96.0;
                    totalTableWidth += colWidths[c];
                }
                if (totalTableWidth > contentWidth && totalTableWidth > 0.0) {
                    CGFloat scale = contentWidth / totalTableWidth;
                    totalTableWidth = 0.0;
                    for (NSUInteger c = 0; c < numCols; c++) {
                        colWidths[c] = floor(colWidths[c] * scale);
                        totalTableWidth += colWidths[c];
                    }
                }
                CGFloat tableOffsetX = MAX(0.0, floor((contentWidth - totalTableWidth) * 0.5));

                NSMutableParagraphStyle *tableRowPara = [[NSMutableParagraphStyle alloc] init];
                tableRowPara.firstLineHeadIndent = tableOffsetX + 14.0;
                tableRowPara.headIndent = tableOffsetX + 14.0;
                tableRowPara.minimumLineHeight = 30.0;
                tableRowPara.maximumLineHeight = 30.0;
                tableRowPara.lineSpacing = 0.0;
                tableRowPara.paragraphSpacing = 0.0;
                tableRowPara.paragraphSpacingBefore = 0.0;

                NSMutableParagraphStyle *sepCollapsedPara = [[NSMutableParagraphStyle alloc] init];
                sepCollapsedPara.minimumLineHeight = 3.0;
                sepCollapsedPara.maximumLineHeight = 3.0;
                sepCollapsedPara.lineSpacing = 0.0;
                sepCollapsedPara.paragraphSpacing = 0.0;
                sepCollapsedPara.paragraphSpacingBefore = 0.0;

                NSFont *headerCellFont = [NSFont systemFontOfSize:baseFontSize - 1.0 weight:NSFontWeightSemibold];
                NSFont *bodyCellFont = [NSFont systemFontOfSize:baseFontSize - 1.0 weight:NSFontWeightRegular];

                for (NSUInteger r = 0; r < tableRows.count; r++) {
                    ZedCapturedBlockDecoration *tr = tableRows[r];
                    NSRange rowRange = NSIntersectionRange(tr.charRange, fullRange);
                    if (rowRange.length == 0) continue;
                    BOOL isRowActive = NSIntersectionRange(rowRange, activeLineRange).length > 0 ||
                                       (savedSel.location >= rowRange.location && savedSel.location <= NSMaxRange(rowRange));
                    BOOL isHeader = (tr.level & 1) != 0;
                    BOOL isSep = (tr.level & 2) != 0;

                    if (isRowActive) {
                        [ts addAttributes:@{
                            NSFontAttributeName: monoFont,
                            NSForegroundColorAttributeName: textFg,
                            NSParagraphStyleAttributeName: tableRowPara
                        } range:rowRange];
                    } else if (isSep) {
                        [ts addAttributes:@{
                            NSFontAttributeName: collapsedFont,
                            NSForegroundColorAttributeName: [NSColor clearColor],
                            NSParagraphStyleAttributeName: sepCollapsedPara
                        } range:rowRange];
                    } else {
                        [ts addAttributes:@{
                            NSFontAttributeName: isHeader ? headerCellFont : bodyCellFont,
                            NSForegroundColorAttributeName: isHeader ? headingFg : textFg,
                            NSParagraphStyleAttributeName: tableRowPara,
                            NSBaselineOffsetAttributeName: @(-5.0)
                        } range:rowRange];

                        // Fold pipe characters on inactive table rows and advance each cell to its column boundary
                        NSString *rowSub = [text substringWithRange:rowRange];
                        NSUInteger colIdx = 0;
                        for (NSUInteger chIdx = 0; chIdx < rowSub.length; chIdx++) {
                            unichar ch = [rowSub characterAtIndex:chIdx];
                            if (ch == '|') {
                                NSRange pipeRange = NSMakeRange(rowRange.location + chIdx, 1);
                                [ts addAttribute:NSForegroundColorAttributeName value:[NSColor clearColor] range:pipeRange];
                                if (colIdx > 0 && colIdx <= numCols) {
                                    [ts addAttribute:NSKernAttributeName value:@(22.0) range:pipeRange];
                                }
                                colIdx++;
                            }
                        }
                    }
                }

                free(colWidths);
            }

            bIdx = nextIdx;
        }

        // Apply Zed DisplayMap Folds (collapse_completely == true) on inactive lines!
        for (size_t i = 0; i < frame->folds_len; i++) {
            const CGpuiFoldSpan *fold = &frame->folds[i];
            if (!fold->collapse_completely) continue;
            size_t s = MIN(fold->byte_start, utf8Len);
            size_t e = MIN(MAX(s, fold->byte_end), utf8Len);
            NSUInteger uStart = byteToU16[s];
            NSUInteger uEnd = byteToU16[e];
            if (uEnd > uStart && uEnd <= fullRange.length) {
                NSRange foldRange = NSMakeRange(uStart, uEnd - uStart);
                [ts addAttributes:@{
                    NSFontAttributeName: collapsedFont,
                    NSForegroundColorAttributeName: [NSColor clearColor]
                } range:foldRange];
            }
        }

        // Apply 2D Inline Math Canvases ($...$) on inactive lines via ZedGPUIMathAttachmentCell
        for (ZedCapturedMathCanvas *ic in inlineCanvases) {
            NSRange r = NSIntersectionRange(ic.charRange, fullRange);
            if (r.length == 0) continue;
            if (r.length > 1) {
                [ts addAttributes:@{
                    NSFontAttributeName: collapsedFont,
                    NSForegroundColorAttributeName: [NSColor clearColor]
                } range:NSMakeRange(r.location, r.length - 1)];
            }
            ZedGPUIMathAttachmentCell *cell = [[ZedGPUIMathAttachmentCell alloc] init];
            cell.canvas = ic;
            cell.mathColor = headingFg;
            cell.badgeBgColor = [codeBg colorWithAlphaComponent:0.65];
            NSTextAttachment *att = [[NSTextAttachment alloc] init];
            att.attachmentCell = cell;
            [ts addAttribute:NSAttachmentAttributeName value:att range:NSMakeRange(NSMaxRange(r) - 1, 1)];
        }

        [ts endEditing];
        if (NSMaxRange(savedSel) <= ts.length) {
            [self.editorView setSelectedRange:savedSel];
        }
        self.isApplyingAttributes = NO;
    }

    free(byteToU16);
    [self.editorView setNeedsDisplay:YES];
}

@end

static void RenderFrameBridgeCallback(void *cb_ctx, const CGpuiRenderFrame *frame) {
    ZedWindowController *controller = (__bridge ZedWindowController *)cb_ctx;
    if (controller && frame) {
        [controller applyRustRenderFrame:frame];
    }
}

// ============================================================================
// Public C Entrypoint Called by Rust `gpui::gpui_macos_run_window`
// ============================================================================

void gpui_macos_run_window(
    void* user_data,
    const char* initial_text_utf8,
    CGpuiEvaluateFn evaluate_fn,
    CGpuiNewlineFn newline_fn,
    CGpuiSetFenceLangFn set_fence_lang_fn,
    CGpuiFreeStringFn free_string_fn
) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSString *initialText = initial_text_utf8
            ? [NSString stringWithUTF8String:initial_text_utf8]
            : @"# OpenType in Zed\n";

        ZedWindowController *delegate = [[ZedWindowController alloc] initWithInitialText:initialText];
        delegate.rustUserData = user_data;
        delegate.evaluateFn = evaluate_fn;
        delegate.newlineFn = newline_fn;
        delegate.setFenceLangFn = set_fence_lang_fn;
        delegate.freeStringFn = free_string_fn;

        app.delegate = delegate;
        [app run];
    }
}
