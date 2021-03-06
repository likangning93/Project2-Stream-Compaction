#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
namespace Efficient {

cudaEvent_t start, stop;

static void setup_timer_events() {
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	cudaEventRecord(start);
}

static float teardown_timer_events() {
	cudaEventRecord(stop);

	cudaEventSynchronize(stop);
	float milliseconds = 0;
	cudaEventElapsedTime(&milliseconds, start, stop);

	cudaEventDestroy(start);
	cudaEventDestroy(stop);

	return milliseconds;
}

// TODO: __global__

__global__ void upsweep_step(int d_offset_plus, int d_offset, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	if (k % d_offset_plus) {
		return;
	}
	x[k + d_offset_plus - 1] += x[k + d_offset - 1];
}

__global__ void downsweep_step(int d_offset_plus, int d_offset, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	if (k % d_offset_plus) {
		return;
	}
	int t = x[k + d_offset - 1];
	x[k + d_offset - 1] = x[k + d_offset_plus - 1];
	x[k + d_offset_plus - 1] += t;
}

__global__ void fill_by_value(int val, int *x) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	x[k] = val;
}

static void setup_dimms(dim3 &dimBlock, dim3 &dimGrid, int n) {
	cudaDeviceProp deviceProp;
	cudaGetDeviceProperties(&deviceProp, 0);
	int tpb = deviceProp.maxThreadsPerBlock;
	int blockWidth = fmin(n, tpb);
	int blocks = 1;
	if (blockWidth != n) {
		blocks = n / tpb;
		if (n % tpb) {
			blocks ++;
		}
	}

	dimBlock = dim3(blockWidth);
	dimGrid = dim3(blocks);
}

/**
 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
 */
void scan(int n, int *odata, const int *idata) {

	// copy everything in idata over to the GPU.
	// we'll need to pad the device memory with 0s to get a power of 2 array size.
	int logn = ilog2ceil(n);
	int pow2 = (int)pow(2, logn);

	dim3 dimBlock;
	dim3 dimGrid;
	setup_dimms(dimBlock, dimGrid, pow2);

	int *dev_x;
	cudaMalloc((void**)&dev_x, sizeof(int) * pow2);
	fill_by_value <<<dimGrid, dimBlock >>>(0, dev_x);

	cudaMemcpy(dev_x, idata, sizeof(int) * n, cudaMemcpyHostToDevice);

	if (BENCHMARK) {
		setup_timer_events();
	}

	// up sweep and down sweep
	up_sweep_down_sweep(pow2, dev_x);

	if (BENCHMARK) {
		printf("%f microseconds.\n",
			teardown_timer_events() * 1000.0f);
	}

	cudaMemcpy(odata, dev_x, sizeof(int) * n, cudaMemcpyDeviceToHost);
	cudaFree(dev_x);
}

// exposed up sweep and down sweep. expects powers of two!
void up_sweep_down_sweep(int n, int *dev_data1) {
	int logn = ilog2ceil(n);

	dim3 dimBlock;
	dim3 dimGrid;
	setup_dimms(dimBlock, dimGrid, n);

	// Up Sweep
	for (int d = 0; d < logn; d++) {
		int d_offset_plus = (int)pow(2, d + 1);
		int d_offset = (int)pow(2, d);
		upsweep_step << <dimGrid, dimBlock >> >(d_offset_plus, d_offset, dev_data1);
	}

	//debug: peek at the array after upsweep
	//int peek1[8];
	//cudaMemcpy(&peek1, dev_data1, sizeof(int) * 8, cudaMemcpyDeviceToHost);

	// Down-Sweep
	//int zero[1];
	//zero[0] = 0;
	//cudaMemcpy(&dev_data1[n - 1], zero, sizeof(int) * 1, cudaMemcpyHostToDevice);
	cudaMemset(&dev_data1[n - 1], 0, sizeof(int) * 1);
	for (int d = logn - 1; d >= 0; d--) {
		int d_offset_plus = (int)pow(2, d + 1);
		int d_offset = (int)pow(2, d);
		downsweep_step << <dimGrid, dimBlock >> >(d_offset_plus, d_offset, dev_data1);
	}
}

__global__ void temporary_array(int *x, int *temp) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	temp[k] = (x[k] != 0);
}

__global__ void scatter(int *x, int *trueFalse, int* scan, int *out) {
	int k = threadIdx.x + (blockIdx.x * blockDim.x);
	if (trueFalse[k]) {
		out[scan[k]] = x[k];
	}
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
	int logn = ilog2ceil(n);
	int pow2 = (int)pow(2, logn);

	dim3 dimBlock;
	dim3 dimGrid;
	setup_dimms(dimBlock, dimGrid, pow2);

	int *dev_x;
	int *dev_tmp;
	int *dev_scatter;
	int *dev_scan;

	cudaMalloc((void**)&dev_x, sizeof(int) * pow2);
	cudaMalloc((void**)&dev_tmp, sizeof(int) * pow2);
	cudaMalloc((void**)&dev_scan, sizeof(int) * pow2);
	cudaMalloc((void**)&dev_scatter, sizeof(int) * pow2);

	// 0 pad up to a power of 2 array length.
	// copy everything in idata over to the GPU.
	fill_by_value << <dimGrid, dimBlock >> >(0, dev_x);
	cudaMemcpy(dev_x, idata, sizeof(int) * n, cudaMemcpyHostToDevice);

	if (BENCHMARK) {
		setup_timer_events();
	}

    // Step 1: compute temporary true/false array
	temporary_array <<<dimGrid, dimBlock >>>(dev_x, dev_tmp);

	// Step 2: run efficient scan on the tmp array
	cudaMemcpy(dev_scan, dev_tmp, sizeof(int) * pow2, cudaMemcpyDeviceToDevice);
	up_sweep_down_sweep(pow2, dev_scan);

	// Step 3: scatter
	scatter <<<dimGrid, dimBlock >>>(dev_x, dev_tmp, dev_scan, dev_scatter);

	if (BENCHMARK) {
		printf("%f microseconds.\n",
			teardown_timer_events() * 1000.0f);
	}

	cudaMemcpy(odata, dev_scatter, sizeof(int) * n, cudaMemcpyDeviceToHost);

	int last_index;
	cudaMemcpy(&last_index, dev_scan + (n - 1), sizeof(int),
		cudaMemcpyDeviceToHost);

	int last_true_false;
	cudaMemcpy(&last_true_false, dev_tmp + (n - 1), sizeof(int),
		cudaMemcpyDeviceToHost);

	cudaFree(dev_x);
	cudaFree(dev_tmp);
	cudaFree(dev_scan);
	cudaFree(dev_scatter);

	return last_index + last_true_false;
}

}
}
