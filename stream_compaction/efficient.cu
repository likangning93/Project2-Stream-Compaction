#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
namespace Efficient {

// TODO: __global__

__global__ void upsweep_step(int d, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	if (k % (int) powf(2, d + 1)) {
		return;
	}
	x[k + (int) powf(2, d + 1) - 1] += x[k + (int) powf(2, d) - 1];
}

__global__ void downsweep_step(int d, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	if (k % (int)powf(2, d + 1)) {
		return;
	}
	int t = x[k + (int) powf(2, d) - 1];
	x[k + (int) powf(2, d) - 1] = x[k + (int) powf(2, d + 1) - 1];
	x[k + (int) powf(2, d + 1) - 1] += t;
}

__global__ void fill_by_value(int val, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	x[k] = val;
}

/**
 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
 */
void scan(int n, int *odata, const int *idata) {

	// copy everything in idata over to the GPU.
	// we'll need to pad the device memory with 0s to get a power of 2 array size.
	int logn = ilog2ceil(n);
	int pow2 = (int)pow(2, logn);

	dim3 dimBlock(pow2);
	dim3 dimGrid(1);
	int *dev_x;
	cudaMalloc((void**)&dev_x, sizeof(int) * pow2);
	fill_by_value <<<dimGrid, dimBlock >>>(0, dev_x);

	cudaMemcpy(dev_x, idata, sizeof(int) * n, cudaMemcpyHostToDevice);

    // Up Sweep
	for (int d = 0; d < logn; d++) {
		upsweep_step <<<dimGrid, dimBlock>>>(d, dev_x);
	}

	//debug: peek at the array after upsweep
	int peek[8];
	cudaMemcpy(&peek, dev_x, sizeof(int) * 8, cudaMemcpyDeviceToHost);

	// Down-Sweep
	int zero[1];
	zero[0] = 0;
	cudaMemcpy(&dev_x[pow2 - 1], zero, sizeof(int) * 1, cudaMemcpyHostToDevice);
	for (int d = logn - 1; d >= 0; d--) {
		downsweep_step <<<dimGrid, dimBlock>>>(d, dev_x);
	}

	cudaMemcpy(odata, dev_x, sizeof(int) * n, cudaMemcpyDeviceToHost);
	cudaFree(dev_x);
}

/**
 * Performs stream compaction on idata, storing the result into odata.
 * All zeroes are discarded.
 *
 * @param n      The number of elements in idata.
 * @param odata  The array into which to store elements.
 * @param idata  The array of elements to compact.
 * @returns      The number of elements remaining after compaction.
 */
int compact(int n, int *odata, const int *idata) {
    // TODO
    return -1;
}

}
}
