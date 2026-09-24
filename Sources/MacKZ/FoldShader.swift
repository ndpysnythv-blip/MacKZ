import Foundation

/// Metal 着色器源码（运行时编译，免去单独 metal 编译步骤）。
///
/// 算法 1:1 移植自 DuoHinge（github.com/JoaoFranco03/DuoHinge，MIT License）的 HingeGlass.metal，
/// 复刻 iPhone Duo「Duo Continuity」在 MacBook 上的折叠视错觉：
///
/// 模型：桌面画面固定躺在 z=0 平面；屏幕底边（键盘侧）是虚拟铰链轴；
/// 一整块「虚拟玻璃」绕底边铰链从屏幕平面立起（progress 0→1 对应玻璃角 0°→90°）。
/// 每个屏幕像素 = 玻璃上一点，从固定视点发射线穿过玻璃、打到 z=0 桌面平面求交采样。
/// 玻璃越立起，桌面看起来越向铰链「折倒/收进」——这就是折叠观感的来源，
/// 而不是把画面压缩或二次旋转。
///
/// 三层光学（全部在显示坐标系里做）：
/// 1) 幕布压暗：合上时从屏幕顶部压下一层暗幕，最暗保留 40% 透过率，桌面永不熄灭；
/// 2) 双趟可分离高斯：玻璃离铰链越远、立起越多，散射越大（磨砂玻璃）；
/// 3) 径向色散：围绕底边中点的径向 R/B 反向偏移（Cinematic 风格），铰链接触带保持中性。
enum FoldShader {

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // 距铰链的距离（仅 DuoHinge 折叠样式使用；corner 样式用 MacDuo 自己的几何）
    //   corner = false：铰链在屏幕底边
    //   corner = true ：角落锚点（保留给以后扩展）
    inline float hingeDistance(float2 p, float2 size, bool corner, float flip) {
        if (!corner) return size.y - p.y;
        float2 uv = p / max(size, float2(1.0f));
        float2 anchor = flip > 0.5f ? float2(1.0f, 1.0f) : float2(0.0f, 1.0f);
        return length(uv - anchor) * size.y;   // 折算成像素尺度，复用原有散射公式
    }

    // ---------- 第一趟：固定平面透视投影 ----------
    // 桌面保持在 z=0；只有「玻璃」绕 (y=height, z=0)（屏幕底边）旋转。
    // 对每个玻璃像素，把静止视点的射线延伸到固定桌面平面求交采样。
    float4 hingeGlass(float2 position, texture2d<float> layer, float4 bounds,
                      float progress, float blurStrength, float darknessStrength, float3 viewpoint,
                      float angleScale, float flip) {
        float2 size = bounds.zw;
        float2 p = position - bounds.xy;
        // 玻璃立起角 = progress × 最大角（angleScale = foldAngleDeg / 90）
        float angle = clamp(progress, 0.0f, 1.0f) * clamp(angleScale, 0.05f, 1.0f) * M_PI_F * 0.5f;
        // 参考角（progress=0）下精确直通，避免颜色/几何跳变
        if (angle < 1e-5f) return float4(layer.sample(linearSampler, position / bounds.zw).rgb, 1.0f);

        // 折叠方向：flip=1 → 铰链在屏幕顶边（画面内容向屏幕下方收，MacBook 观感）；
        //            flip=0 → 铰链在屏幕底边（参考实现的原始方向，内容向上抽走）
        bool atTop = flip > 0.5f;
        // 远离铰链的一侧（归一化）：幕布压暗与色散渐变都以它为基准
        float far = atTop ? (1.0f - p.y / size.y) : (p.y / size.y);

        // 幕布压暗：延迟且更宽，绝不熄灭桌面；完全合上时远端保留 40% 透过率
        float curtainProgress = smoothstep(0.20f, 1.0f, clamp(progress, 0.0f, 1.0f));
        float feather = 0.22f;
        float edge = mix(-feather, 0.90f, curtainProgress);
        float curtain = 1.0f - smoothstep(edge - feather, edge + feather, far);
        float visibility = 1.0f - min(0.60f * darknessStrength, 0.80f) * curtain;

        // 参考姿态附近光学散射平滑缓入
        float opticalStrength = smoothstep(0.0f, 1.5f / 90.0f, progress);
        float distance = atTop ? p.y : (size.y - p.y);   // 距铰链的像素高度
        // 视距：以屏高为单位缩放
        float eyeDistance = size.y * max(viewpoint.z, 1.1f);
        float sine = sin(angle);
        float cosine = cos(angle);
        // 视点（固定不动）
        float3 eye = float3(size.x * viewpoint.x, size.y * viewpoint.y, eyeDistance);
        // 玻璃点：绕铰链旋转后，玻璃面立起
        float3 glass = atTop
            ? float3(p.x, distance * cosine, distance * sine)
            : float3(p.x, size.y - distance * cosine, distance * sine);
        float depth = eye.z - glass.z;
        if (depth <= 1e-5f) return float4(0, 0, 0, 1);
        // 射线 eye→glass 延伸到 z=0 平面的交点
        float rayScale = eye.z / depth;
        float2 hit = eye.xy + (glass.xy - eye.xy) * rayScale;
        // 玻璃分离量（决定散射半径）
        float separation = distance * sine;
        // 铰链接触带保持光学清晰；分离越大散射越强；限制核大小避免稀疏鬼影
        float contact = smoothstep(size.y * 0.035f, size.y * 0.20f, distance);
        float scatter = separation * 0.070f * contact * opticalStrength * blurStrength;
        // 平滑饱和：保留变化斜率而非硬性封顶
        float radius = scatter / sqrt(1.0f + (scatter / 36.0f) * (scatter / 36.0f));
        // 投影只采样一次，模糊由后面两趟供给
        bool inside = all(hit >= 0.0f) && all(hit < size);
        float3 color = inside ? layer.sample(linearSampler, (bounds.xy + hit) / bounds.zw).rgb : float3(0);
        float transmission = 1.0f - min(radius * 0.0004f, 0.015f);
        return float4(color * transmission * visibility, 1.0f);
    }

    // ---------- 可分离高斯（显示坐标系） ----------
    // 两条稠密 1D 趟避免稀疏圆盘复制品破坏细小文字；相邻权重共享双线性读取。
    float4 hingeGaussian(float2 position, texture2d<float> layer, float4 bounds,
                          float progress, float2 direction, float blurStrength, float angleScale,
                          float diagonal, float flip) {
        float2 size = bounds.zw;
        float2 p = position - bounds.xy;
        float sigma;
        if (diagonal > 0.5f) {
            // MacDuo Duo 的模糊量（照抄）：sigma 按画面高度的比例给出，blur 取它的默认值 0.65
            float h = clamp(1.0f - p.y / size.y, 0.0f, 1.0f);
            float focus = pow(clamp(progress, 0.0f, 1.0f), 0.7f);
            float spread = 0.12f + 0.88f * pow(h, 1.15f);
            sigma = max(0.65f * 0.052f * focus * spread * size.y, 0.15f);
        } else {
            float distance = size.y - p.y;
            float contact = smoothstep(size.y * 0.035f, size.y * 0.20f, distance);
            float optical = smoothstep(0.0f, 1.5f / 90.0f, progress);
            float angle = clamp(progress, 0.0f, 1.0f) * clamp(angleScale, 0.05f, 1.0f) * M_PI_F * 0.5f;
            float scatter = distance * sin(angle)
                          * 0.070f * contact * optical * blurStrength;
            float radius = scatter / sqrt(1.0f + (scatter / 36.0f) * (scatter / 36.0f));
            if (radius < 0.35f) return float4(layer.sample(linearSampler, position / bounds.zw).rgb, 1);
            sigma = max(radius / 2.44948974f, 0.15f);
        }
        float inverseVariance = 0.5f / (sigma * sigma);
        float3 sum = float3(layer.sample(linearSampler, position / bounds.zw).rgb);
        float total = 1.0f;
        for (int i = 1; i <= 35; i += 2) {
            float a = float(i), b = a + 1.0f;
            float wa = exp(-a * a * inverseVariance);
            float wb = exp(-b * b * inverseVariance);
            float weight = wa + wb;
            if (weight < 1e-7f) continue;
            float offset = (a * wa + b * wb) / weight;
            for (int side = -1; side <= 1; side += 2) {
                // 延伸边缘而不是引入暗色采样边框
                float2 q = clamp(p + direction * (float(side) * offset),
                                 float2(0.0f), max(size - 0.5f, float2(0.0f)));
                sum += float3(layer.sample(linearSampler, (bounds.xy + q) / bounds.zw).rgb) * weight;
            }
            total += 2.0f * weight;
        }
        return float4(sum / total, 1);
    }

    // ---------- 径向色散（NameDrop 风格的再创作，非复刻 Apple 实现） ----------
    // 在模糊之后施加；固定平面投影不受影响。
    float4 hingeChromatic(float2 position, texture2d<float> layer,
                          float4 bounds, float progress, float strength, float flip) {
        float4 center = layer.sample(linearSampler, position / bounds.zw);
        float closing = clamp(progress, 0.0f, 1.0f);
        if (strength <= 0.0f || closing <= 0.0f) return center;

        float2 size = max(bounds.zw, float2(1.0f));
        float2 p = position - bounds.xy;
        bool atTop = flip > 0.5f;
        float heightFromHinge = clamp((atTop ? p.y : (size.y - p.y)) / size.y, 0.0f, 1.0f);
        float contact = smoothstep(0.035f, 0.20f, heightFromHinge);
        float onset = smoothstep(0.0f, 2.5f / 90.0f, closing);
        float amount = min(size.y * 0.009f, 10.0f) * clamp(strength, 0.0f, 1.0f)
                     * sin(closing * M_PI_F * 0.5f) * onset * contact
                     * pow(heightFromHinge, 1.35f);
        if (amount < 0.001f) return center;

        // 围绕铰链的径向色散：窄接触带保持中性，远端与外缘分离增大
        float2 radial = float2((p.x / size.x - 0.5f) * 0.65f,
                               atTop ? heightFromHinge : -heightFromHinge);
        float2 offset = radial / max(length(radial), 0.0001f) * amount;
        float2 upper = max(size - 0.5f, float2(0.0f));
        float2 redPosition = bounds.xy + clamp(p + offset, float2(0.0f), upper);
        float2 bluePosition = bounds.xy + clamp(p - offset, float2(0.0f), upper);
        // 延伸边缘，避免彩色透明镶边
        return float4(layer.sample(linearSampler, redPosition / bounds.zw).r, center.g,
                      layer.sample(linearSampler, bluePosition / bounds.zw).b, center.a);
    }

    // ---------- 备选动画：MacDuo 的 Duo（1:1 照搬） ----------
    // 来源：DhananjayBhosale/MacDuo · Sources/MacDuo/Shader.swift 的 foldEffectPixel()（MIT）。
    // 参数全部用它的默认值：perspective 0.7、blur 0.65、shadow 0.65、defocus -1（用 pow(p,0.7)）。
    // 唯一工程差异：MacDuo 用 mipmap 金字塔做模糊，这里用本工程两趟可分离高斯，sigma 公式照抄。
    float4 cornerGlass(float2 position, texture2d<float> layer, float4 bounds,
                       float progress, float darknessStrength, float flip) {
        float2 size = max(bounds.zw, float2(1.0f));
        float2 screenUV = position / size;
        float p = clamp(progress, 0.0f, 1.0f);
        if (p < 0.00001f) return float4(layer.sample(linearSampler, screenUV).rgb, 1);
        if (p >= 1.0f) return float4(0, 0, 0, 1);

        // —— 以下为 MacDuo foldDuo 原文 ——
        // 物理屏幕本身已提供相机的梯形，这里围绕「底边中心铰链」把画面放大：
        // 图标被放大、上方内容从顶部移出画面；有界映射避免完全合上时出现奇点。
        float height = 1.0f - screenUV.y;
        float expansion = 1.0f + p * (0.12f + mix(0.30f, 0.66f, 0.7f) * height);
        float2 uv = float2(0.5f + (screenUV.x - 0.5f) / expansion, 1.0f - height / expansion);

        // 模糊量：以画面高度的比例计（对应它 pyramid 的 sigma / sigmaUV）
        float focus = pow(p, 0.7f);
        float spread = 0.12f + 0.88f * pow(height, 1.15f);
        float sigmaUV = 0.65f * 0.052f * focus * spread;
        float3 color = layer.sample(linearSampler, uv).rgb;

        float softness = 0.65f;
        float topWidth = p * (0.075f + 0.15f * softness) + 1.5f * sigmaUV;
        float sideWidth = (p * (0.055f + 0.12f * softness) + 1.5f * sigmaUV) * size.y / size.x;
        float bottomWidth = p * (0.012f + 0.025f * softness) + 0.5f * sigmaUV;
        float mask = smoothstep(0.0f, topWidth, screenUV.y) * smoothstep(0.0f, bottomWidth, height)
                   * smoothstep(0.0f, sideWidth, screenUV.x) * smoothstep(0.0f, sideWidth, 1.0f - screenUV.x);
        float shade = 1.0f - 0.65f * 0.12f * p * p * height;
        float disappear = 1.0f - smoothstep(0.86f, 1.0f, p);
        return float4(color * mask * shade * disappear, 1);
    }

    // ---------- Uniform / 顶点 ----------
    struct HingeUniforms {
        float4 geometry;   // 宽、高、progress、blur 强度
        float4 optics;     // 压暗强度、色散强度、玻璃最大立起角比例（foldAngleDeg/90）、折叠方向（1=铰链在顶边）
        float4 eye;        // 视点 x、y、z、动画样式（0=玻璃折叠，1=左下角收起）
    };
    struct HingeVertex { float4 position [[position]]; float2 uv; };

    // 覆盖全屏的大三角形
    vertex HingeVertex hingeVertex(uint index [[vertex_id]]) {
        float2 uv = float2((index << 1) & 2, index & 2);
        return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }

    // 动画样式：1 = 斜轴折叠（往左下角收），0 = 参考实现的底边折叠
    inline bool isCornerStyle(constant HingeUniforms &u) { return u.eye.w > 0.5f; }

    fragment float4 hingeProject(HingeVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                                 constant HingeUniforms &u [[buffer(0)]]) {
        if (isCornerStyle(u)) {
            return cornerGlass(in.uv * u.geometry.xy, source, float4(0, 0, u.geometry.xy),
                               u.geometry.z, u.optics.x, u.optics.w);
        }
        return hingeGlass(in.uv * u.geometry.xy, source, float4(0, 0, u.geometry.xy),
                          u.geometry.z, u.geometry.w, u.optics.x, u.eye.xyz, u.optics.z, u.optics.w);
    }
    fragment float4 hingeBlurX(HingeVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                               constant HingeUniforms &u [[buffer(0)]]) {
        return hingeGaussian(in.uv * u.geometry.xy, source, float4(0, 0, u.geometry.xy),
                             u.geometry.z, float2(1, 0), u.geometry.w, u.optics.z,
                             isCornerStyle(u) ? 1.0f : 0.0f, u.optics.w);
    }
    fragment float4 hingeBlurY(HingeVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                               constant HingeUniforms &u [[buffer(0)]]) {
        return hingeGaussian(in.uv * u.geometry.xy, source, float4(0, 0, u.geometry.xy),
                             u.geometry.z, float2(0, 1), u.geometry.w, u.optics.z,
                             isCornerStyle(u) ? 1.0f : 0.0f, u.optics.w);
    }
    fragment float4 hingeDispersion(HingeVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                                     constant HingeUniforms &u [[buffer(0)]]) {
        // 色散是按「底边铰链」的径向算的，斜轴样式下不适用，直接跳过
        if (isCornerStyle(u)) return float4(source.sample(linearSampler, in.uv).rgb, 1.0f);
        return hingeChromatic(in.uv * u.geometry.xy, source, float4(0, 0, u.geometry.xy),
                              u.geometry.z, u.optics.y, u.optics.w);
    }
    """
}
