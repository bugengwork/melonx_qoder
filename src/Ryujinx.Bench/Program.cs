using Silk.NET.Vulkan;
using Ryujinx.Graphics.Vulkan;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ryujinx.Bench
{
    internal static class Program
    {
        // 阶段1: 裸 fence 生命周期对比（修改方案可行性验证）
        private const int FenceIterations = 20000;

        // 阶段2: 真实 CommandBufferPool 租借循环
        private const int PoolWarmup = 300;
        private const int PoolIterations = 3000;

        private static unsafe void Main()
        {
            Console.WriteLine("Ryujinx.Bench: Vulkan fence / command buffer pool micro-benchmark");
            Console.WriteLine($"工作目录: {Environment.CurrentDirectory}");
            Console.WriteLine();

            var api = Vk.GetApi();

            // --- 最小 Vulkan 环境（复用生产代码包装类） ---
            var appInfo = new ApplicationInfo
            {
                SType = StructureType.ApplicationInfo,
                ApiVersion = Vk.Version12,
            };

            var createInfo = new InstanceCreateInfo
            {
                SType = StructureType.InstanceCreateInfo,
                PApplicationInfo = &appInfo,
            };

            VulkanInstance.Create(api, ref createInfo, out var instance).ThrowOnError();
            using var rawInstance = instance;

            rawInstance.EnumeratePhysicalDevices(out VulkanPhysicalDevice[] physicalDevices).ThrowOnError();
            var physicalDevice = physicalDevices[0];

            uint queueFamilyIndex = 0;
            for (uint i = 0; i < physicalDevice.QueueFamilyProperties.Length; i++)
            {
                if ((physicalDevice.QueueFamilyProperties[i].QueueFlags & QueueFlags.GraphicsBit) != 0)
                {
                    queueFamilyIndex = i;
                    break;
                }
            }

            var device = VulkanInitialization.CreateDevice(api, physicalDevice, queueFamilyIndex, 1);

            api.GetDeviceQueue(device, queueFamilyIndex, 0, out var queue);

            Console.WriteLine($"物理设备: {physicalDevice.DeviceName}");
            Console.WriteLine($"QueueFamily: {queueFamilyIndex}");
            Console.WriteLine();

            BenchFenceLifecycle(api, device, queue);

            BenchCommandBufferPool(api, device, queue, queueFamilyIndex);

            api.DestroyDevice(device, null);
            rawInstance.Dispose();

            Console.WriteLine();
            Console.WriteLine("完成。");
        }

        /// <summary>
        /// 阶段1：对比「Create/Destroy fence」与「复用 + ResetFences」的驱动开销。
        /// 两种场景都提交空 command buffer 并等待完成，模拟真实提交路径，
        /// 唯一差异是 fence 生命周期管理方式。
        /// </summary>
        private static unsafe void BenchFenceLifecycle(Vk api, Device device, Queue queue)
        {
            // 分配一个空 command buffer（两场景共用，每轮 reset 后重录）
            var poolCreateInfo = new CommandPoolCreateInfo
            {
                SType = StructureType.CommandPoolCreateInfo,
                Flags = CommandPoolCreateFlags.TransientBit | CommandPoolCreateFlags.ResetCommandBufferBit,
            };

            api.CreateCommandPool(device, in poolCreateInfo, null, out var commandPool).ThrowOnError();

            var allocateInfo = new CommandBufferAllocateInfo
            {
                SType = StructureType.CommandBufferAllocateInfo,
                CommandPool = commandPool,
                CommandBufferCount = 1,
                Level = CommandBufferLevel.Primary,
            };

            api.AllocateCommandBuffers(device, in allocateInfo, out var commandBuffer).ThrowOnError();

            var fenceCreateInfo = new FenceCreateInfo { SType = StructureType.FenceCreateInfo };

            void RecordAndSubmit(CommandBuffer cb, Fence fence)
            {
                var beginInfo = new CommandBufferBeginInfo { SType = StructureType.CommandBufferBeginInfo };
                api.BeginCommandBuffer(cb, in beginInfo).ThrowOnError();
                api.EndCommandBuffer(cb).ThrowOnError();

                var submitInfo = new SubmitInfo
                {
                    SType = StructureType.SubmitInfo,
                    CommandBufferCount = 1,
                    PCommandBuffers = &cb,
                };

                api.QueueSubmit(queue, 1, in submitInfo, fence).ThrowOnError();
                api.WaitForFences(device, 1, in fence, true, ulong.MaxValue).ThrowOnError();
                api.ResetCommandBuffer(cb, CommandBufferResetFlags.None).ThrowOnError();
            }

            // --- 场景 A：每轮 CreateFence + DestroyFence（当前 CommandBufferPool 行为） ---
            {
                // warmup
                for (int i = 0; i < 500; i++)
                {
                    api.CreateFence(device, in fenceCreateInfo, null, out var warmFence).ThrowOnError();
                    RecordAndSubmit(commandBuffer, warmFence);
                    api.DestroyFence(device, warmFence, Span<AllocationCallbacks>.Empty);
                }

                var sw = Stopwatch.StartNew();
                for (int i = 0; i < FenceIterations; i++)
                {
                    api.CreateFence(device, in fenceCreateInfo, null, out var fence).ThrowOnError();
                    RecordAndSubmit(commandBuffer, fence);
                    api.DestroyFence(device, fence, Span<AllocationCallbacks>.Empty);
                }
                sw.Stop();

                double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / FenceIterations;
                Console.WriteLine($"[场景A] Create+Submit+Wait+Destroy x{FenceIterations}: 总 {sw.ElapsedMilliseconds} ms, 每轮 {perOp:F0} ns");
            }

            // --- 场景 B：Create 一次，每轮 Submit+Wait+ResetFences（优化方案） ---
            {
                api.CreateFence(device, in fenceCreateInfo, null, out var reusedFence).ThrowOnError();

                // warmup
                for (int i = 0; i < 500; i++)
                {
                    RecordAndSubmit(commandBuffer, reusedFence);
                    api.ResetFences(device, 1, in reusedFence).ThrowOnError();
                }

                var sw = Stopwatch.StartNew();
                for (int i = 0; i < FenceIterations; i++)
                {
                    RecordAndSubmit(commandBuffer, reusedFence);
                    api.ResetFences(device, 1, in reusedFence).ThrowOnError();
                }
                sw.Stop();

                double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / FenceIterations;
                Console.WriteLine($"[场景B] Create一次+Submit+Wait+Reset x{FenceIterations}: 总 {sw.ElapsedMilliseconds} ms, 每轮 {perOp:F0} ns");

                api.DestroyFence(device, reusedFence, Span<AllocationCallbacks>.Empty);
            }

            api.DestroyCommandPool(device, commandPool, null);

            // --- 场景 C/D：隔离 fence 生命周期本身的开销（无提交干扰） ---
            {
                var sw = Stopwatch.StartNew();
                for (int i = 0; i < FenceIterations; i++)
                {
                    api.CreateFence(device, in fenceCreateInfo, null, out var f).ThrowOnError();
                    api.DestroyFence(device, f, Span<AllocationCallbacks>.Empty);
                }
                sw.Stop();

                double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / FenceIterations;
                Console.WriteLine($"[场景C] 纯 CreateFence+DestroyFence x{FenceIterations}: 总 {sw.ElapsedMilliseconds} ms, 每轮 {perOp:F0} ns");
            }

            {
                api.CreateFence(device, in fenceCreateInfo, null, out var f).ThrowOnError();

                var sw = Stopwatch.StartNew();
                for (int i = 0; i < FenceIterations; i++)
                {
                    api.ResetFences(device, 1, in f).ThrowOnError();
                }
                sw.Stop();

                double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / FenceIterations;
                Console.WriteLine($"[场景D] 纯 ResetFences x{FenceIterations}: 总 {sw.ElapsedMilliseconds} ms, 每轮 {perOp:F0} ns");

                api.DestroyFence(device, f, Span<AllocationCallbacks>.Empty);
            }

            Console.WriteLine();
        }

        /// <summary>
        /// 阶段2：直接压测生产代码 CommandBufferPool 的 Rent/Return 循环。
        /// Return 会真实提交到队列（EndCommandBuffer + QueueSubmit + fence 管理），
        /// 与模拟器帧提交路径一致。
        /// </summary>
        private static unsafe void BenchCommandBufferPool(Vk api, Device device, Queue queue, uint queueFamilyIndex)
        {
            using var pool = new CommandBufferPool(api, device, queue, new object(), queueFamilyIndex, false);

            // warmup
            for (int i = 0; i < PoolWarmup; i++)
            {
                var cbs = pool.Rent();
                pool.Return(cbs);
            }

            var sw = Stopwatch.StartNew();
            for (int i = 0; i < PoolIterations; i++)
            {
                var cbs = pool.Rent();
                pool.Return(cbs);
            }
            sw.Stop();

            double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / PoolIterations;
            Console.WriteLine($"[CommandBufferPool] Rent/Return x{PoolIterations}: 总 {sw.ElapsedMilliseconds} ms, 每轮 {perOp:F0} ns");

            Console.WriteLine();
        }
    }
}
