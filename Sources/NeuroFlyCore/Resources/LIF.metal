// LIF.metal
//
// The two kernels are adapted from SiliconFly's MIT-licensed whole-brain
// simulator. They retain its fixed-point scatter topology and deterministic
// PCG noise stream, while NeuroFly routes six virtual receptor channels to
// annotated sensory neurons only.
//
// SiliconFly source: https://github.com/dawsonamf/siliconfly
// See ThirdParty/SiliconFly-LICENSE in this package.

#include <metal_stdlib>
using namespace metal;

struct StepParams {
    uint n;
    uint slot;
    uint stepIndex;
    uint curSlot;
    uint inhSlot;
    uint seed;
    uint refractory;
    float invFx;
    float decay;
    float threshold;
    float pNoise;
    float noiseKick;
    float activityScale;
    float odorLeft;
    float odorRight;
    float taste;
    float loomingLeft;
    float loomingRight;
    float touch;
};

static inline uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// One update thread per neuron. inputKind values are assigned only to
// ORN/GRN/visual/sensory neurons by BrainEngine; command neurons never receive
// external input directly.
kernel void lif_update(
    device float* v [[buffer(0)]],
    device uchar* refr [[buffer(1)]],
    device const float* baseline [[buffer(2)]],
    device const uchar* inputKind [[buffer(3)]],
    device const uchar* groupOf [[buffer(4)]],
    device const float* extInput [[buffer(5)]],
    device atomic_int* excAcc [[buffer(6)]],
    device atomic_int* inhRing [[buffer(7)]],
    device uint* spikeList [[buffer(8)]],
    device atomic_uint* spikeCount [[buffer(9)]],
    device atomic_uint* groupCounts [[buffer(10)]],
    constant StepParams& P [[buffer(11)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= P.n) return;

    float vi = v[gid];
    int ex = atomic_exchange_explicit(&excAcc[gid], 0, memory_order_relaxed);
    if (ex != 0) vi = max(-2.0f, vi + float(ex) * P.invFx);

    uint h = pcg(pcg(P.seed + P.stepIndex * 2654435761u) + gid);
    uint r = refr[gid];
    if (r > 0u) {
        refr[gid] = uchar(r - 1u);
        vi *= P.decay;
    } else {
        vi = vi * P.decay + baseline[gid] * P.activityScale;
        if (float(h >> 8u) * 5.9604645e-8f < P.pNoise) vi += P.noiseKick;
    }

    uchar kind = inputKind[gid];
    if (kind == 1u) vi += P.odorLeft;
    else if (kind == 2u) vi += P.odorRight;
    else if (kind == 3u) vi += P.taste;
    else if (kind == 4u) vi += P.loomingLeft;
    else if (kind == 5u) vi += P.loomingRight;
    else if (kind == 6u) vi += P.touch;
    vi += extInput[gid];

    int inh = atomic_exchange_explicit(&inhRing[P.curSlot * P.n + gid],
                                       0, memory_order_relaxed);
    if (inh != 0) vi = max(-2.0f, vi + float(inh) * P.invFx);

    bool spike = (r <= 1u) && vi >= P.threshold;
    if (spike) {
        vi = 0.0f;
        refr[gid] = uchar(P.refractory);
    }
    v[gid] = vi;

    if (spike) {
        uint index = atomic_fetch_add_explicit(&spikeCount[P.slot], 1u,
                                               memory_order_relaxed);
        spikeList[index] = gid;
        uchar group = groupOf[gid];
        if (group != 0u) {
            atomic_fetch_add_explicit(&groupCounts[P.slot * 12u + uint(group) - 1u],
                                      1u, memory_order_relaxed);
        }
    }
}

// One SIMD group per spiking neuron. Only outgoing edges of neurons that
// spiked in the current step are touched, preserving the sparse CSR design.
kernel void lif_propagate(
    device atomic_int* excAcc [[buffer(6)]],
    device atomic_int* inhRing [[buffer(7)]],
    device const uint* spikeList [[buffer(8)]],
    device const uint* spikeCount [[buffer(9)]],
    device const uint* rowStart [[buffer(12)]],
    device const uint* colIdx [[buffer(13)]],
    device const int* weightFx [[buffer(14)]],
    constant StepParams& P [[buffer(11)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ntg [[threadgroups_per_grid]],
    uint lane [[thread_position_in_threadgroup]],
    uint width [[threads_per_threadgroup]])
{
    uint count = spikeCount[P.slot];
    uint inhBase = P.inhSlot * P.n;
    for (uint t = tgid; t < count; t += ntg) {
        uint source = spikeList[t];
        uint begin = rowStart[source];
        uint end = rowStart[source + 1u];
        for (uint k = begin + lane; k < end; k += width) {
            int weight = weightFx[k];
            uint target = colIdx[k];
            if (weight >= 0) {
                atomic_fetch_add_explicit(&excAcc[target], weight, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(&inhRing[inhBase + target], weight,
                                          memory_order_relaxed);
            }
        }
    }
}
