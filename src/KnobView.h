//
//  KnobView.h — 一个可拖动的旋钮控件
//
//  旋钮显示：一个圆盘 + 一根指针 + 参数名 + 数值。
//  拖动圆盘上下改值，拖动即实时发 MIDI（回调 onChange）。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface KnobView : NSView

// 参数信息
@property(nonatomic, copy)   NSString *label;      // 参数名，如 "Cutoff"
@property(nonatomic, copy)   NSString *ccLabel;    // "CC74" / "CC7 · Device Volume"
@property(nonatomic, assign) int   ccNumber;       // 实际发送的 CC 号
@property(nonatomic, assign) int   value;          // 0..127
@property(nonatomic, assign) int   maxValue;       // 一般 127
@property(nonatomic, assign) BOOL  isSwitch;       // 开关型：0 或 maxValue

// 值变化回调（实时发送用）
@property(nonatomic, copy, nullable) void (^onChange)(KnobView *knob);

// 底色/强调色
@property(nonatomic, strong) NSColor *accentColor;

- (void)setValueAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
