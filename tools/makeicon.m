//
//  makeicon.m — 生成 Plugiator ASX 控制台的 App 图标（纯 AppKit 绘制，无外部素材）
//  用法：clang -fobjc-arc -framework Cocoa -o tools/makeicon tools/makeicon.m
//        tools/makeicon <输出目录>      # 会生成 AppIcon.iconset/
//

#import <Cocoa/Cocoa.h>

// 板子的样子：一块深色扩展板 + 一排琴键 + 一个跳出来的旋钮
static void DrawIcon(CGFloat s) {
    NSRect r = NSMakeRect(0, 0, s, s);

    // 圆角深色底
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(s * 0.04, s * 0.04, s * 0.92, s * 0.92)
                                                    xRadius:s * 0.22 yRadius:s * 0.22];
    NSGradient *g = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.18 green:0.18 blue:0.22 alpha:1]
                  endingColor:[NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.10 alpha:1]];
    [g drawInBezierPath:bg angle:-90];

    // 顶部一条彩色条 = 插件槽（留出旋钮的位置）
    NSBezierPath *stripe = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(s * 0.15, s * 0.805, s * 0.40, s * 0.068)
                                                    xRadius:s * 0.035 yRadius:s * 0.035];
    [[NSColor colorWithSRGBRed:1.0 green:0.69 blue:0.13 alpha:1] setFill];
    [stripe fill];

    // 琴键：5 白键
    NSRect keyArea = NSMakeRect(s * 0.15, s * 0.17, s * 0.70, s * 0.44);
    CGFloat kw = keyArea.size.width / 5.0;
    for (int i = 0; i < 5; i++) {
        NSRect k = NSMakeRect(keyArea.origin.x + i * kw + s * 0.012,
                              keyArea.origin.y, kw - s * 0.024, keyArea.size.height);
        NSBezierPath *kp = [NSBezierPath bezierPathWithRoundedRect:
            NSMakeRect(k.origin.x, k.origin.y, k.size.width, k.size.height - s * 0.05)
                                                        xRadius:s * 0.018 yRadius:s * 0.018];
        [[NSColor colorWithWhite:0.96 alpha:1] setFill];
        [kp fill];
    }
    // 黑键（2+3 分组）
    CGFloat bh = keyArea.size.height * 0.58;
    const int blacks[] = {0, 1, 3, 4};   // 标准 2+3 分组里的黑键位置
    for (int i = 0; i < 4; i++) {
        NSRect k = NSMakeRect(keyArea.origin.x + blacks[i] * kw + kw * 0.62,
                              keyArea.origin.y + keyArea.size.height - bh,
                              kw * 0.44, bh);
        NSBezierPath *kp = [NSBezierPath bezierPathWithRoundedRect:k
                                                            xRadius:s * 0.012 yRadius:s * 0.012];
        [[NSColor colorWithWhite:0.10 alpha:1] setFill];
        [kp fill];
    }

    // 右上角一个旋钮（板子的旋钮 = 参数）
    CGFloat kx = s * 0.745, ky = s * 0.72, kr = s * 0.135;
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(kx - kr, ky - kr, kr * 2, kr * 2)];
    ring.lineWidth = s * 0.055;
    [[NSColor colorWithSRGBRed:1.0 green:0.69 blue:0.13 alpha:1] setStroke];
    [ring stroke];
    // 指针
    NSBezierPath *ptr = [NSBezierPath bezierPath];
    [ptr moveToPoint:NSMakePoint(kx, ky)];
    [ptr lineToPoint:NSMakePoint(kx + kr * 0.55, ky + kr * 0.55)];
    ptr.lineWidth = s * 0.05;
    [ptr setLineCapStyle:NSLineCapStyleRound];
    [[NSColor colorWithSRGBRed:1.0 green:0.69 blue:0.13 alpha:1] setStroke];
    [ptr stroke];
}

static BOOL WritePNG(NSImage *img, NSString *path) {
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    // 注意：不能用 NSDataWritingAtomic（外接 exFAT 盘上原子写会失败）
    return [png writeToFile:path options:0 error:NULL];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = (argc > 1) ? @(argv[1]) : @"AppIcon.iconset";
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:NULL];

        const int sizes[] = {16, 32, 64, 128, 256, 512, 1024};
        for (int i = 0; i < 7; i++) {
            int px = sizes[i];
            NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(px, px)];
            [img lockFocus];
            NSRect bounds = NSMakeRect(0, 0, px, px);
            [[NSColor clearColor] setFill];
            NSRectFill(bounds);                 // 保持透明，不能铺色（会出黑边）
            DrawIcon(px);
            [img unlockFocus];

            NSString *name;
            if (px <= 512) {
                if (px == 16)      name = @"icon_16x16.png";
                else if (px == 32) name = @"icon_16x16@2x.png";
                else if (px == 64) name = @"icon_32x32.png";
                else if (px == 128)name = @"icon_32x32@2x.png";
                else if (px == 256)name = @"icon_128x128.png";
                else               name = @"icon_128x128@2x.png";
            } else {
                name = @"icon_256x256.png";
            }
            WritePNG(img, [out stringByAppendingPathComponent:name]);
            if (px == 512) WritePNG(img, [out stringByAppendingPathComponent:@"icon_256x256.png"]);
        }
        printf("图标已生成到 %s\n", out.UTF8String);
    }
    return 0;
}
