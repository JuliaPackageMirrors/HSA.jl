using HSA
using HSA.Intrinsics
using HSA.Execution
using FactCheck

using HSA.Execution: prepare_args, cleanup_args, get_or_init_defaults, clear_defaults,
                     build_kernel, allocate_args, kernel_cache, build_dispatch

@hsa_kernel function vcopy(a,b)
	idx = get_global_id(Int32(0)) + 1

	x = Base.unsafe_load(a, idx)
	Base.unsafe_store!(b, x, idx)
	return nothing
end

@hsa_kernel function vadd(a,b,c)
	i = get_global_id(Int32(0)) + 1
	c[i] = a[i] + b[i]
	return nothing
end

@hsa_kernel function mmul(a,b,c,arows,acols)
	# one kernel invocation per column of the result matrix
	# i = col
	i = get_global_id(Int32(0))
	# j = row
	for j = 1:arows
		c_ij = 0.0
		for k = 1:acols
			a_idx = (k-1) * arows + j
			b_idx = i * acols + k
			c_ij += a[a_idx] * b[b_idx]
		end

		c_idx = i * arows + j
		c[c_idx] = c_ij
	end
	return nothing
end

@hsa_kernel function mmul2d(a,b,c,acols)
	# one kernel invocation per cell of the result matrix
	arows = get_global_size(Int32(0))
	# i = col
	i = get_global_id(Int32(0))
	# j = row
	j = get_global_id(Int32(1)) + 1

	c_ij = 0.0
	for k = 1:acols
		a_idx = (k-1) * arows + j
		b_idx = i * acols + k
		c_ij += a[a_idx] * b[b_idx]
	end

	c_idx = i * arows + j
	c[c_idx] = c_ij

	return nothing
end

facts("The execution framework") do
	context("can execute a 2d matrix multiplication") do
		const arows = 3
		const acols = 4

		a = Array(Float64, arows, acols); rand!(a)
		b = Array(Float64, acols, arows); rand!(b)
		c = Array(Float64, arows, arows); rand!(c)
		c_expected = a * b

		@hsa (arows, arows) mmul2d(a,b,c,acols)

		@fact c --> c_expected
	end
	context("manages the configuration details for kernel invocations") do
		# does not hold a runtime reference initially
		@fact_throws HSA.status_string(4107)

		cfg = get_or_init_defaults()

		@fact HSA.status_string(4107) --> anything # does not throw
		@fact cfg.queue --> anything
		@fact cfg.agent --> anything

		# disposes runtime reference
		clear_defaults()

		@fact_throws HSA.status_string(4107)
	end

	context("can automatically convert kernel arguments") do
		rt = Runtime()

		context("Arrays to pointers, registering the Memory with the runtime") do
			args = Array[ Array(Int, 10), Array(Float64, 5) ]

			kargs = prepare_args(args)

			for ka in kargs
				@fact ka --> x -> isa(x, Ptr)
			end

			cleanup_args(args)
		end

		finalize(rt)
	end


	context("can build a kernel and cache the executable") do
		cfg = get_or_init_defaults()
		@fact length(kernel_cache) --> 0

		kernel_info = build_kernel(cfg.agent, vadd, [Ptr{Float64},Ptr{Float64},Ptr{Float64}])

		@fact kernel_info --> anything
		@fact length(kernel_cache) --> 1

		kernel_info2 = build_kernel(cfg.agent, vadd, [Ptr{Float64}, Ptr{Float64}, Ptr{Float64}])

		@fact kernel_info2 --> kernel_info
		@fact length(kernel_cache) --> 1
	end

	context("can allocate memory for arguments") do
		cfg = get_or_init_defaults()
		kernel_info = build_kernel(cfg.agent, vadd, [Ptr{Float64},Ptr{Float64},Ptr{Float64}])

		args = Any[Ptr{Float64}(0), Ptr{Float64}(0), Ptr{Float64}(0)]

		#println(HSA.Compilation.src_hsail(vadd, Tuple{Ptr{Float64},Ptr{Float64},Ptr{Float64}}))

		karg_memory = allocate_args(cfg.agent, kernel_info, args)

		@fact karg_memory.ptr --> not(0)
	end

	context("can build the dispatch packet") do
		cfg = get_or_init_defaults()
		kernel_info = build_kernel(cfg.agent, vadd, [Ptr{Float64},Ptr{Float64},Ptr{Float64}])
		args = Any[Ptr{Float64}(1), Ptr{Float64}(2), Ptr{Float64}(3)]
		karg_memory = allocate_args(cfg.agent, kernel_info, args)

		signal = Signal(value = 1)

		packet = build_dispatch((100,), kernel_info, karg_memory, signal)

		@fact packet --> x -> isa(x, HSA.KernelDispatchPacket)

		finalize(karg_memory)
		finalize(signal)
	end

	context("can execute a vector copy") do
		const N = 1000

        a = Array(Int,N); rand!(a)
        b = Array(Int,N); rand!(b)
		expected = copy(a)

		@hsa (N) vcopy(a,b)

		@fact b --> expected
	end

	context("can execute a float vector copy") do
		const N = 1000

        a = Array(Float64,N); rand!(a)
        b = Array(Float64,N); rand!(b)
		expected = copy(a)

		@hsa (N) vcopy(a,b)

		@fact b --> expected
	end

	context("can execute a vector add") do
		const n = 100
		args = Array[ Array(Int, n), Array(Int, n), Array(Int, n) ]

		for a in args
			rand!(a)
		end

		expected = args[1] + args[2]

		println(macroexpand(:(@hsa (n) vadd(args[1], args[2], args[3]))))
		@hsa (n) vadd(args[1], args[2], args[3])

		@fact args[3] --> expected
	end

	context("can execute a simple matrix multiplication") do
		const arows = 3
		const acols = 4

		a = Array(Float64, arows, acols); rand!(a)
		b = Array(Float64, acols, arows); rand!(b)
		c = Array(Float64, arows, arows); rand!(c)
		c_expected = a * b

		println(macroexpand(:(@hsa (acols) mmul(a,b,c,arows,acols))))
		@hsa (arows) mmul(a,b,c,arows,acols)

		@fact c --> c_expected
	end
end