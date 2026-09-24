// Minimal memory helper used by RNNoise v0.2's ARM/scalar vector kernels.
// The upstream v0.2 archive references os_support.h but omits it.
#ifndef ALTRANSCRIBE_RNNOISE_OS_SUPPORT_H
#define ALTRANSCRIBE_RNNOISE_OS_SUPPORT_H
#include <string.h>
#define OPUS_CLEAR(destination, count) memset((destination), 0, (count) * sizeof(*(destination)))
#endif
