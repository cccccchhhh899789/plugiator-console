//
//  KnobView.m
//

#import "KnobView.h"

@implementation KnobView {
    BOOL _dragging;
    double _dragStartY;
    int   _dragStartValue;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _value = 0;
        _maxValue = 127;
        _label = @"";
        _ccLabel = @"";
        _accentColor = [NSColor colorWithSRGBRed:1.0 green:0.69 blue:0.13 alpha:1];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

// 旋钮圆盘所在区域（上部）
- (NSRect)dialRect {
    NSRect b = self.bounds;
    CGFloat d = MIN(b.size.width, b.size.height * 0.62);
    return NSMakeRect(NSMidX(b) - d / 2.0, b.size.height - d - 2, d, d);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect dial = [self dialRect];
    CGFloat r = dial.size.width / 2.0;
    NSPoint c = NSMakePoint(NSMidX(dial), NSMidY(dial));

    // 底盘
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - r * 0.72, c.y - r * 0.72, r * 1.44, r * 1.44)];
    track.lineWidth = r * 0.16;
    [[NSColor colorWithWhite:0.25 alpha:1] setStroke];
    [track stroke];

    // 已调过的部分（弧）
    double frac = (self.maxValue > 0) ? (double)self.value / (double)self.maxValue : 0;
    if (frac > 0.001) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        // 顺时针增大：弧段从 (225-270*frac) 逆时针扫回 225（几何 = 从 7:30 顺时针铺到 4:30），
        // 起止对调后 delta 恒为正，不依赖 AppKit 的 clockwise 参数语义
        [arc appendBezierPathWithArcWithCenter:c radius:r * 0.72
                                       startAngle:225 - 270 * frac endAngle:225];
        arc.lineWidth = r * 0.16;
        arc.lineCapStyle = NSLineCapStyleRound;
        [self.accentColor setStroke];
        [arc stroke];
    }

    // 旋钮本体
    NSBezierPath *cap = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - r * 0.5, c.y - r * 0.5, r, r)];
    NSGradient *g = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithWhite:0.92 alpha:1]
                  endingColor:[NSColor colorWithWhite:0.74 alpha:1]];
    [g drawInBezierPath:cap angle:-90];

    // 指针
    // 指针：与弧同步顺时针——frac 0 = 7:30，0.5 = 12:00 正上，1 = 4:30
    double ang = (225 - 270 * frac) * M_PI / 180.0;
    NSPoint tip = NSMakePoint(c.x + cos(ang) * r * 0.42, c.y + sin(ang) * r * 0.42);
    NSBezierPath *ptr = [NSBezierPath bezierPath];
    [ptr moveToPoint:c];
    [ptr lineToPoint:tip];
    ptr.lineWidth = r * 0.1;
    ptr.lineCapStyle = NSLineCapStyleRound;
    [[NSColor colorWithWhite:0.18 alpha:1] setStroke];
    [ptr stroke];

    // 参数名
    NSRect nameRect = NSMakeRect(self.bounds.origin.x, self.bounds.origin.y,
                                 self.bounds.size.width, 15);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSString *nm = self.label;
    [nm drawInRect:nameRect withAttributes:attrs];

    // CC 号 + 数值
    NSRect valRect = NSMakeRect(self.bounds.origin.x, self.bounds.origin.y + 14,
                                self.bounds.size.width, 13);
    NSDictionary *vattrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9
                                                              weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    NSString *vs = self.isSwitch
        ? (self.value >= (self.maxValue / 2) ? @"ON" : @"OFF")
        : [NSString stringWithFormat:@"%@  %d", self.ccLabel, self.value];
    [vs drawInRect:valRect withAttributes:vattrs];
}

- (void)setValue:(int)value {
    int v = MAX(0, MIN(self.maxValue, value));
    if (_value == v) return;
    _value = v;
    [self setNeedsDisplay:YES];
}

- (void)setValueAnimated:(BOOL)animated {
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    _dragStartY = event.locationInWindow.y;
    _dragStartValue = self.value;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    // 上下拖 150pt 对应满量程
    double dy = event.locationInWindow.y - _dragStartY;
    double delta = dy / 150.0 * (double)self.maxValue;
    int nv = (int)lround(_dragStartValue + delta);
    if (nv < 0) nv = 0;
    if (nv > self.maxValue) nv = self.maxValue;
    if (self.isSwitch) nv = (nv >= self.maxValue / 2) ? self.maxValue : 0;
    if (nv != self.value) {
        self.value = nv;
        [self setNeedsDisplay:YES];
        if (self.onChange) self.onChange(self);   // 实时发送
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging) return;
    _dragging = NO;
    if (self.onChange) self.onChange(self);       // 松手再补一次，保证最终值送达
}

@end
