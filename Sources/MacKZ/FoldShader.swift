import Foundation

/// Metal 着色器源码（运行时编译，免去单独 metal 编译步骤）。
///
/// 算法（与 DuoHinge 同路线）：
/// 1) **射线投射**：把屏幕每个像素当作从观察点出发的射线，与「虚拟折叠面」求交
///    （折叠面 = 上下两块半平面，绕折痕轴各旋转 φ），交点再反算回平板坐标 → 得到采样 UV。
///    因此透视是真实几何透视，不是图层 rotateX + m34 近似；
/// 2) **两趟高斯玻璃模糊**：第一趟横向模糊（半径随离折痕的距离递增），
///    第二趟在重投影时做纵向模糊 → 等效可分离高斯，磨砂玻璃质感；
/// 3) **色散**：R/G/B 用略有差异的折痕参数采样，折痕与边缘出现青/品红边；
/// 4) 未命中折叠面的像素（折叠后露出的空隙）用大幅模糊 + 压暗的桌面填充，形成环境背景。
enum FoldShader {

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 texelSize;      // 1 / 纹理尺寸
        float  creaseRatio;    // 折痕位置（0=屏幕顶，1=屏幕底）
        float  foldAngle;      // 折痕两侧各自的旋转角（弧度，已钳制）
        float  eyeDistance;    // 视距（以屏高为单位）
        float  blurStrength;   // 渐进模糊强度 0~1
        float  dispersion;     // 色散强度 0~1
        float  fade;           // 整体不透明度（序列两端淡入淡出）
        float  aspect;         // 宽 / 高
        float  halfWidth;      // 0.5 * aspect
        float  brightness;     // 背景压暗系数
    };

    struct VSOut { float4 pos [[position]]; float2 uv; };

    // 全屏三角形（比两个三角形更省）
    vertex VSOut vsFull(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 q = p[vid];
        VSOut o;
        o.pos = float4(q, 0.0, 1.0);
        o.uv  = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);   // 与屏幕一致：左上为原点
        return o;
    }

    // 离折痕越近模糊越强（磨砂玻璃的厚度感）
    static inline float blurRadiusAt(float v, constant Uniforms& U, float maxRadius) {
        float dist = fabs(v - U.creaseRatio);          // 源坐标（左上原点）
        float near = 1.0 - clamp(dist / 0.5, 0.0, 1.0);
        return maxRadius * (0.35 + 0.65 * near) * max(U.blurStrength, 0.0);
    }

    // 第一趟：横向高斯模糊（7 抽头，两段半径叠加出更大的模糊范围）
    fragment float4 fsBlurH(VSOut in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            constant Uniforms& U [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float maxRadius = max(U.texelSize.y > 0.0 ? (1.0 / U.texelSize.y) * 0.016 : 12.0, 4.0);
        float r = blurRadiusAt(in.uv.y, U, maxRadius);
        const float w[4] = { 0.2161, 0.1870, 0.0796, 0.0167 };
        float4 acc = src.sample(s, in.uv) * 0.2410;
        for (int i = 1; i <= 3; ++i) {
            float o = float(i) * (r / 3.0) * U.texelSize.x;
            acc += src.sample(s, in.uv + float2(o, 0.0)) * w[i - 1];
            acc += src.sample(s, in.uv - float2(o, 0.0)) * w[i - 1];
        }
        return acc;
    }

    // 折叠面单侧求交：
    // sign = +1 上半（y > yc，折痕上方），-1 下半
    // 折叠面参数：折痕在 yc，离折痕距离 d 的点 → (x, yc + sign*d*cosφ, -d*sinφ)
    static inline bool foldHit(float x0, float y0, float sign, float yc,
                               float c, float s, float D,
                               thread float2& flat) {
        float denom = sign * s * y0 - c * D;
        float num   = sign * s * yc - c * D;
        if (fabs(denom) < 1e-6) return false;
        float t = num / denom;
        if (t <= 0.0 || t > 1.0) return false;
        float yh = t * y0;
        float d  = sign * (yh - yc) / max(c, 1e-3);
        if (d < 0.0 || d > 1.0) return false;
        flat = float2(t * x0, yc + sign * d);
        return true;
    }

    // 第二趟：纵向模糊 + 折叠重投影 + 色散
    fragment float4 fsFold(VSOut in [[stage_in]],
                           texture2d<float> blurTex [[texture(0)]],
                           constant Uniforms& U [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        // 目标像素 -> 平板空间（y 向上，中心为原点，单位为屏高）
        float x0 = (in.uv.x - 0.5) * U.aspect;
        float y0 = 0.5 - in.uv.y;
        float yc = 0.5 - U.creaseRatio;
        float D  = max(U.eyeDistance, 0.8);
        float c  = cos(U.foldAngle), sn = sin(U.foldAngle);

        float2 flat;
        bool hit = false;
        if (y0 >= yc) {
            hit = foldHit(x0, y0,  1.0, yc, c, sn, D, flat);
        }
        if (!hit) {
            hit = foldHit(x0, y0, -1.0, yc, c, sn, D, flat);
        }

        // 未命中：折叠后露出的空隙 → 大幅模糊 + 压暗的环境背景
        if (!hit || fabs(flat.x) > U.halfWidth || fabs(flat.y) > 0.5) {
            float4 amb = float4(0.0);
            float rr = 0.045;
            amb += blurTex.sample(s, in.uv);
            amb += blurTex.sample(s, in.uv + float2( rr, 0.0));
            amb += blurTex.sample(s, in.uv + float2(-rr, 0.0));
            amb += blurTex.sample(s, in.uv + float2(0.0,  rr));
            amb += blurTex.sample(s, in.uv + float2(0.0, -rr));
            amb *= 0.2;
            // 中心亮、四周暗，像设备之外的暗场
            float vig = 1.0 - clamp(length((in.uv - 0.5) * float2(1.0, 1.2)) * 0.9, 0.0, 1.0);
            float3 col = amb.rgb * U.brightness * (0.35 + 0.65 * vig);
            return float4(col * U.fade, U.fade);
        }

        // 反算源 UV（左上原点）
        float2 uv = float2(flat.x / U.aspect + 0.5, 0.5 - flat.y);
        float dCrease = fabs(flat.y - yc);                       // 离折痕距离
        float foldAmount = clamp(U.foldAngle / 1.3, 0.0, 1.0);   // 折叠程度 0~1

        // 纵向模糊（第二趟），半径与横向一致
        float maxRadius = max((1.0 / U.texelSize.y) * 0.016, 4.0);
        float r = blurRadiusAt(uv.y, U, maxRadius);
        const float w[4] = { 0.2161, 0.1870, 0.0796, 0.0167 };

        // 色散：三通道用略不同的折痕距离回退，形成青/品红边缘
        float disp = U.dispersion * foldAmount * 0.9;
        float3 col = float3(0.0);
        for (int ch = 0; ch < 3; ++ch) {
            float off = (float(ch) - 1.0) * disp * (0.004 + 0.010 * (1.0 - clamp(dCrease * 2.0, 0.0, 1.0)));
            float2 uvCh = float2(uv.x + off, uv.y);
            float4 acc = blurTex.sample(s, uvCh) * 0.2410;
            for (int i = 1; i <= 3; ++i) {
                float o = float(i) * (r / 3.0) * U.texelSize.y;
                acc += blurTex.sample(s, uvCh + float2(0.0, o)) * w[i - 1];
                acc += blurTex.sample(s, uvCh - float2(0.0, o)) * w[i - 1];
            }
            col[ch] = acc[ch];
        }

        // 折痕高光：折得越紧，折痕线越亮（玻璃棱边的高光）
        float glow = exp(-dCrease * 90.0) * foldAmount * 0.55;
        float edgeGlow = exp(-dCrease * 14.0) * foldAmount * 0.10;
        col += glow + edgeGlow;

        // 玻璃边缘轻微提亮，避免折叠后显得脏
        col = mix(col, col * 1.06, foldAmount);
        col *= 1.0 + 0.05 * foldAmount;

        return float4(col * U.fade, U.fade);
    }
    """
}
