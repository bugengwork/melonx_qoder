using ARMeilleure.Decoders;
using ARMeilleure.Memory;
using ARMeilleure.Native;
using ARMeilleure.State;
using ARMeilleure.Translation;
using Ryujinx.Cpu;
using Ryujinx.Cpu.Jit;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ryujinx.Bench
{
    /// <summary>
    /// ARMeilleure JIT 微基准：量化 guest 代码的翻译吞吐与执行吞吐，
    /// 为 CPU 模拟侧的性能优化提供基线。
    /// </summary>
    internal static class JitBench
    {
        private const ulong CodeAddress = 0x1000;
        private const ulong DataAddress = 0x200000;

        // guest 侧循环迭代次数（一次 Execute 内完成，避开 Translator 自毁语义）
        private const ulong AluLoopIterations = 1_000_000;
        private const ulong MemLoopIterations = 500_000;
        private const int TranslateIterations = 2000;

        /// <summary>
        /// 基于 byte[] 的最小 IMemoryManager 实现。
        /// </summary>
        private sealed class SimpleMemoryManager : IMemoryManager
        {
            private readonly byte[] _data;
            private readonly GCHandle _handle;

            public int AddressSpaceBits => 48;

            // HostMapped 模式下翻译器生成 hostPtr = PageTablePointer + guestVA，
            // 必须返回已固定的连续内存基址，否则 ldr/str 会访问非法 host 地址。
            public IntPtr PageTablePointer => _handle.AddrOfPinnedObject();

            public MemoryManagerType Type => MemoryManagerType.HostMappedUnsafe;

            public event Action<ulong, ulong> UnmapEvent;

            public SimpleMemoryManager(int size)
            {
                _data = new byte[size];
                _handle = GCHandle.Alloc(_data, GCHandleType.Pinned);
            }

            public void Write(uint offset, ReadOnlySpan<byte> data)
            {
                data.CopyTo(_data.AsSpan((int)offset));
            }

            public T Read<T>(ulong va) where T : unmanaged
            {
                return MemoryMarshal.Read<T>(_data.AsSpan((int)va, Marshal.SizeOf<T>()));
            }

            public T ReadTracked<T>(ulong va) where T : unmanaged
            {
                return Read<T>(va);
            }

            public void Write<T>(ulong va, T value) where T : unmanaged
            {
                MemoryMarshal.Write(_data.AsSpan((int)va, Marshal.SizeOf<T>()), ref value);
            }

            public ReadOnlySpan<byte> GetSpan(ulong va, int size, bool tracked = false)
            {
                return _data.AsSpan((int)va, size);
            }

            public ref T GetRef<T>(ulong va) where T : unmanaged
            {
                return ref MemoryMarshal.GetReference(MemoryMarshal.Cast<byte, T>(_data.AsSpan((int)va, Marshal.SizeOf<T>())));
            }

            public bool IsMapped(ulong va)
            {
                return va < (ulong)_data.Length;
            }

            public void SignalMemoryTracking(ulong va, ulong size, bool write, bool precise = false, int? exemptId = null)
            {
            }
        }

        private static void WriteUint32(SimpleMemoryManager memory, ulong address, params uint[] words)
        {
            byte[] buffer = new byte[words.Length * 4];

            for (int i = 0; i < words.Length; i++)
            {
                BitConverter.TryWriteBytes(buffer.AsSpan(i * 4, 4), words[i]);
            }

            memory.Write((uint)address, buffer);
        }

        public static void Run()
        {
            Console.WriteLine("=== ARMeilleure JIT 微基准 ===");
            Console.WriteLine();

            var memory = new SimpleMemoryManager(256 * 1024 * 1024);
            Console.WriteLine("内存管理器就绪");

            // 注意：Translator.Execute 自毁语义（threadCount 归零时 Dispose Stubs），
            // 每个场景必须使用独立的 Translator 实例。
            BenchTranslateThroughput(memory);
            BenchDecodeAlone(memory);
            // 临时注释其余场景，专注采样翻译阶段
            if (false)
            {
                BenchAluExecute(memory);
                BenchMemExecute(memory);
                BenchCrossBlockDispatch(memory);
                BenchCrossBlockDirect(memory);
                BenchTranslateOverhead();
            }

            Console.WriteLine();
        }

        /// <summary>
        /// 场景1：纯算术链执行吞吐。
        /// guest 循环 1M 次 × 40 条 ALU 指令，单次 Execute 完成，测翻译代码热执行速度。
        /// </summary>
        private static void BenchAluExecute(SimpleMemoryManager memory)
        {
            var translator = new Translator(new JitMemoryAllocator(forJit: true), memory, for64Bits: true);
            uint[] alu =
            {
                // loop 起点（回跳目标）
                0x8B010000, // add x0, x0, x1
                0xCB020021, // sub x1, x1, x2
                0x9B017C00, // mul x0, x0, x1
                0x8A010003, // and x3, x0, x1
                0xAA030000, // orr x0, x0, x3
                0xCA010042, // eor x2, x2, x1
                0x8B030063, // add x3, x3, x3
                0xD37DF000, // lsl x0, x0, #2
                0x8B010000, // add x0, x0, x1
                0xCB020021, // sub x1, x1, x2
                0x9B017C00, // mul x0, x0, x1
                0x8A010003, // and x3, x0, x1
                0xAA030000, // orr x0, x0, x3
                0xCA010042, // eor x2, x2, x1
                0x8B030063, // add x3, x3, x3
                0xD37DF000, // lsl x0, x0, #2
                0x8B010000, // add x0, x0, x1
                0xCB020021, // sub x1, x1, x2
                0x9B017C00, // mul x0, x0, x1
                0x8A010003, // and x3, x0, x1
                0xAA030000, // orr x0, x0, x3
                0xCA010042, // eor x2, x2, x1
                0x8B030063, // add x3, x3, x3
                0xD37DF000, // lsl x0, x0, #2
                0x8B010000, // add x0, x0, x1
                0xCB020021, // sub x1, x1, x2
                0x9B017C00, // mul x0, x0, x1
                0x8A010003, // and x3, x0, x1
                0xAA030000, // orr x0, x0, x3
                0xCA010042, // eor x2, x2, x1
                0x8B030063, // add x3, x3, x3
                0xD37DF000, // lsl x0, x0, #2
                0x8B010000, // add x0, x0, x1
                0xCB020021, // sub x1, x1, x2
                0x9B017C00, // mul x0, x0, x1
                0x8A010003, // and x3, x0, x1
                0xAA030000, // orr x0, x0, x3
                0xCA010042, // eor x2, x2, x1
                0xF1000484, // subs x4, x4, #1
                0x54FFFBE1, // b.ne loop（回跳 33 条，imm19=-33）
                0xD65F03C0, // ret
            };

            WriteUint32(memory, CodeAddress, alu);

            var context = new ExecutionContext(new JitMemoryAllocator(forJit: true), new TickSource(19200000));

            context.SetX(0, 1);
            context.SetX(1, 2);
            context.SetX(2, 3);
            context.SetX(3, 4);
            context.SetX(4, AluLoopIterations);

            var sw = Stopwatch.StartNew();
            translator.Execute(context, CodeAddress);
            sw.Stop();

            ulong totalInstructions = AluLoopIterations * 34; // 32 ALU + subs + b.ne
            double nsPerGuestInstr = sw.Elapsed.TotalMilliseconds * 1e6 / totalInstructions;
            Console.WriteLine($"[JIT-ALU] guest循环 {AluLoopIterations} 次 x34指令: 总 {sw.ElapsedMilliseconds} ms, {nsPerGuestInstr:F2} ns/指令");
        }

        /// <summary>
        /// 场景2：内存 load/store + 算术循环执行吞吐。
        /// guest 循环 50 万次 × 5 条指令（ldr/str/subs/b.ne），测内存发射路径。
        /// </summary>
        private static void BenchMemExecute(SimpleMemoryManager memory)
        {
            var translator = new Translator(new JitMemoryAllocator(forJit: true), memory, for64Bits: true);
            uint[] memLoop =
            {
                0xF9400085, // ldr x5, [x4]
                0x8B050000, // add x0, x0, x5
                0xF9000885, // str x5, [x4, #16] (imm12=2)
                0xF1000463, // subs x3, x3, #1
                0x54FFFF81, // b.ne loop (回跳 4 条)
                0xD65F03C0, // ret
            };

            WriteUint32(memory, CodeAddress, memLoop);

            var context = new ExecutionContext(new JitMemoryAllocator(forJit: true), new TickSource(19200000));

            context.SetX(0, 0);
            context.SetX(3, MemLoopIterations);
            context.SetX(4, DataAddress);

            memory.Write(DataAddress, 5ul);

            var sw = Stopwatch.StartNew();
            translator.Execute(context, CodeAddress);
            sw.Stop();

            ulong totalInstructions = MemLoopIterations * 5;
            double nsPerGuestInstr = sw.Elapsed.TotalMilliseconds * 1e6 / totalInstructions;
            Console.WriteLine($"[JIT-MEM] guest循环 {MemLoopIterations} 次 x5指令: 总 {sw.ElapsedMilliseconds} ms, {nsPerGuestInstr:F2} ns/指令");
        }

        /// <summary>
        /// 场景3：翻译吞吐。对不同大小块分层测量，定位翻译固定开销与指令级成本。
        /// </summary>
        private static void BenchTranslateThroughput(SimpleMemoryManager memory)
        {
            var translator = new Translator(new JitMemoryAllocator(forJit: true), memory, for64Bits: true);

            // 用不同大小的块分层测量：
            //   1 指令（ret）→ 接近纯固定开销
            //   4 / 16 / 64 指令 → 固定开销被逐步摊销
            int[] blockSizes = { 1, 4, 16, 64 };
            int[] iterations = { 200000, 100000, 50000, 20000 };

            const ulong stride = 0x200;

            for (int b = 0; b < blockSizes.Length; b++)
            {
                int blockSize = blockSizes[b];
                int count = iterations[b];

                uint[] code = new uint[blockSize];
                for (int i = 0; i < blockSize - 1; i++)
                {
                    code[i] = 0x8B010000; // add x0, x0, x1（链式依赖，无分支）
                }
                code[blockSize - 1] = 0xD65F03C0; // ret

                for (int i = 0; i < count; i++)
                {
                    WriteUint32(memory, CodeAddress + (ulong)i * stride, code);
                }

                // 热身：触发 .NET JIT Tier1 优化，避免冷启动污染计时。
                const int warmupCount = 2000;
                for (int i = 0; i < warmupCount; i++)
                {
                    translator.Translate(CodeAddress + (ulong)i * stride, ExecutionMode.Aarch64, highCq: false);
                }

                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();

                // 计时：持有引用（生产语义）——Functions 缓存持有 TranslatedFunction，
                // Counter 不排队终结，测纯翻译管线成本。
                var held = new List<TranslatedFunction>(count);
                var swHeld = Stopwatch.StartNew();
                for (int i = 0; i < count; i++)
                {
                    held.Add(translator.Translate(CodeAddress + (ulong)i * stride, ExecutionMode.Aarch64, highCq: false));
                }
                swHeld.Stop();

                double perBlockHeld = swHeld.Elapsed.TotalMilliseconds * 1e6 / count;
                Console.WriteLine($"[JIT-TRANSLATE] {blockSize}指令块 x{count}（持有，热身{warmupCount}）: 总 {swHeld.ElapsedMilliseconds} ms, {perBlockHeld:F0} ns/块 ({perBlockHeld / blockSize:F0} ns/指令)");
            }
        }

        /// <summary>
        /// 场景4：跨块 dispatch 成本。br 间接分支强制走 dispatch 路径。
        /// 真实游戏块均 5-10 条指令，块转换频率极高，测每次转换的完整成本。
        /// </summary>
        private static void BenchCrossBlockDispatch(SimpleMemoryManager memory)
        {
            var translator = new Translator(new JitMemoryAllocator(forJit: true), memory, for64Bits: true);

            const ulong BlockA = 0x1000;
            const ulong BlockB = 0x2000;
            const ulong LoopIterations = 1_000_000;

            uint[] blockA =
            {
                0xF1000484, // 0x1000: subs x4, x4, #1
                0x54000160, // 0x1004: b.eq exit（imm19=11 → 0x1030）
                0x8B010000, // 0x1008: add x0, x0, x1
                0xCB020021, // 0x100C: sub x1, x1, x2
                0x9B017C00, // 0x1010: mul x0, x0, x1
                0x8A010003, // 0x1014: and x3, x0, x1
                0xAA030000, // 0x1018: orr x0, x0, x3
                0xCA010042, // 0x101C: eor x2, x2, x1
                0x8B030063, // 0x1020: add x3, x3, x3
                0xD37DF000, // 0x1024: lsl x0, x0, #2
                0xD2840005, // 0x1028: movz x5, #0x2000
                0xD61F00A0, // 0x102C: br x5 → BlockB（强制 dispatch）
                0xD65F03C0, // 0x1030: ret (exit)
            };

            uint[] blockB =
            {
                0x8B010000, // 0x2000: add x0, x0, x1
                0xCB020021, // 0x2004: sub x1, x1, x2
                0x9B017C00, // 0x2008: mul x0, x0, x1
                0x8A010003, // 0x200C: and x3, x0, x1
                0xAA030000, // 0x2010: orr x0, x0, x3
                0xCA010042, // 0x2014: eor x2, x2, x1
                0x8B030063, // 0x2018: add x3, x3, x3
                0xD37DF000, // 0x201C: lsl x0, x0, #2
                0xD2820005, // 0x2020: movz x5, #0x1000
                0xD61F00A0, // 0x2024: br x5 → BlockA（强制 dispatch）
            };

            WriteUint32(memory, BlockA, blockA);
            WriteUint32(memory, BlockB, blockB);

            var context = new ExecutionContext(new JitMemoryAllocator(forJit: true), new TickSource(19200000));

            context.SetX(0, 1);
            context.SetX(1, 2);
            context.SetX(2, 3);
            context.SetX(3, LoopIterations); // x3 = B 块循环计数器
            context.SetX(4, LoopIterations); // x4 = A 块退出计数器
            context.SetX(6, 5);

            var sw = Stopwatch.StartNew();
            translator.Execute(context, BlockA);
            sw.Stop();

            ulong blockSwitches = LoopIterations * 2;
            ulong guestInstructions = LoopIterations * 22; // 12 (A) + 10 (B)
            double nsPerSwitch = sw.Elapsed.TotalMilliseconds * 1e6 / blockSwitches;
            double nsPerInstr = sw.Elapsed.TotalMilliseconds * 1e6 / guestInstructions;
            Console.WriteLine($"[JIT-DISPATCH-br] 跨块循环 {LoopIterations} 次(2块/次): 总 {sw.ElapsedMilliseconds} ms, {nsPerSwitch:F1} ns/块转换, {nsPerInstr:F2} ns/指令");
        }

        /// <summary>
        /// 场景5：跨块直接分支 b 跳转成本（LCQ/块内路径对比）。
        /// </summary>
        private static void BenchCrossBlockDirect(SimpleMemoryManager memory)
        {
            var translator = new Translator(new JitMemoryAllocator(forJit: true), memory, for64Bits: true);

            const ulong BlockA = 0x1000;
            const ulong BlockB = 0x2000;
            const ulong LoopIterations = 1_000_000;

            uint[] blockA =
            {
                0xF1000484, // 0x1000: subs x4, x4, #1
                0x54000140, // 0x1004: b.eq exit（imm19=10 → 0x102C）
                0x8B010000, // 0x1008: add x0, x0, x1
                0xCB020021, // 0x100C: sub x1, x1, x2
                0x9B017C00, // 0x1010: mul x0, x0, x1
                0x8A010006, // 0x1014: and x6, x0, x1
                0xAA060000, // 0x1018: orr x0, x0, x6
                0xCA010042, // 0x101C: eor x2, x2, x1
                0x8B0600C6, // 0x1020: add x6, x6, x6
                0xD37DF000, // 0x1024: lsl x0, x0, #2
                0x140003F6, // 0x1028: b BlockB（imm26=0x3F6）
                0xD65F03C0, // 0x102C: ret (exit)
            };

            uint[] blockB =
            {
                0x8B010000, // 0x2000: add x0, x0, x1
                0xCB020021, // 0x2004: sub x1, x1, x2
                0x9B017C00, // 0x2008: mul x0, x0, x1
                0x8A010006, // 0x200C: and x6, x0, x1
                0xAA060000, // 0x2010: orr x0, x0, x6
                0xCA010042, // 0x2014: eor x2, x2, x1
                0x8B0600C6, // 0x2018: add x6, x6, x6
                0xD37DF000, // 0x201C: lsl x0, x0, #2
                0xF1000463, // 0x2020: subs x3, x3, #1（x3 为循环计数器，ALU 链避开）
                0x54FF7EE1, // 0x2024: b.ne BlockA（imm19=-1033，条件回跳）
                0xD65F03C0, // 0x2028: ret（x3 归零后 fallthrough）
            };

            WriteUint32(memory, BlockA, blockA);
            WriteUint32(memory, BlockB, blockB);

            var context = new ExecutionContext(new JitMemoryAllocator(forJit: true), new TickSource(19200000));

            context.SetX(0, 1);
            context.SetX(1, 2);
            context.SetX(2, 3);
            context.SetX(3, LoopIterations); // x3 = B 块循环计数器
            context.SetX(4, LoopIterations); // x4 = A 块退出计数器
            context.SetX(6, 5);

            var sw = Stopwatch.StartNew();
            translator.Execute(context, BlockA);
            sw.Stop();

            ulong blockSwitches = LoopIterations * 2;
            ulong guestInstructions = LoopIterations * 21; // 11 (A) + 10 (B)，ret 不计
            double nsPerSwitch = sw.Elapsed.TotalMilliseconds * 1e6 / blockSwitches;
            double nsPerInstr = sw.Elapsed.TotalMilliseconds * 1e6 / guestInstructions;
            Console.WriteLine($"[JIT-DISPATCH-b] 跨块循环 {LoopIterations} 次(2块/次): 总 {sw.ElapsedMilliseconds} ms, {nsPerSwitch:F1} ns/块转换, {nsPerInstr:F2} ns/指令");
        }

        /// <summary>
        /// 场景6：翻译固定开销拆解。测每次翻译块必经的 JIT 内存分配与 Darwin 写路径
        /// （pthread_jit_write_protect + memcpy + sys_icache_invalidate）成本。
        /// </summary>
        private static void BenchTranslateOverhead()
        {
            const int Iterations = 2000;
            const int CodeSize = 1024; // 典型 64 指令块的 host 代码量级

            var allocator = new JitMemoryAllocator(forJit: true);

            byte[] code = new byte[CodeSize];
            new Random(42).NextBytes(code);

            // 6a：纯 JIT 内存分配
            var sw = Stopwatch.StartNew();
            for (int i = 0; i < Iterations; i++)
            {
                using IJitMemoryBlock block = allocator.Allocate((ulong)CodeSize);
                _ = block.Pointer;
            }
            sw.Stop();
            Console.WriteLine($"[JIT-OVERHEAD] JIT内存分配 x{Iterations}: {sw.Elapsed.TotalMilliseconds * 1e6 / Iterations:F0} ns/次");

            // 6b：Darwin 写路径（Copy = pthread_jit_write_protect_np + memcpy + sys_icache_invalidate）
            using IJitMemoryBlock dstBlock = allocator.Allocate((ulong)CodeSize);
            IntPtr dst = dstBlock.Pointer;

            sw.Restart();
            for (int i = 0; i < Iterations; i++)
            {
                JitSupportDarwin.Copy(dst, Marshal.UnsafeAddrOfPinnedArrayElement(code, 0), (ulong)CodeSize);
            }
            sw.Stop();
            Console.WriteLine($"[JIT-OVERHEAD] Darwin写路径(1KB) x{Iterations}: {sw.Elapsed.TotalMilliseconds * 1e6 / Iterations:F0} ns/次");

            // 6c：纯 memcpy 对照（无 jit_write_protect / icache flush）
            byte[] dstArray = new byte[CodeSize];

            sw.Restart();
            for (int i = 0; i < Iterations; i++)
            {
                code.CopyTo(dstArray, 0);
            }
            sw.Stop();
            Console.WriteLine($"[JIT-OVERHEAD] 纯memcpy(1KB) x{Iterations}: {sw.Elapsed.TotalMilliseconds * 1e6 / Iterations:F0} ns/次");
        }

        /// <summary>
        /// 场景7：Decoder.Decode 单独计时。与 Translate 总成本差分，
        /// 定位解码 vs Emit+Compile 的占比。
        /// </summary>
        private static void BenchDecodeAlone(SimpleMemoryManager memory)
        {
            const int Iterations = 5000;
            const int BlockSize = 64;

            uint[] code = new uint[BlockSize];
            for (int i = 0; i < BlockSize - 1; i++)
            {
                code[i] = 0x8B010000; // add x0, x0, x1
            }
            code[BlockSize - 1] = 0xD65F03C0; // ret

            const ulong stride = 0x200;

            for (int i = 0; i < Iterations; i++)
            {
                WriteUint32(memory, CodeAddress + (ulong)i * stride, code);
            }

            var sw = Stopwatch.StartNew();
            for (int i = 0; i < Iterations; i++)
            {
                _ = Decoder.Decode(memory, CodeAddress + (ulong)i * stride, ExecutionMode.Aarch64, highCq: false, DecoderMode.MultipleBlocks);
            }
            sw.Stop();

            double perOp = sw.Elapsed.TotalMilliseconds * 1e6 / Iterations;
            Console.WriteLine($"[JIT-DECODE] {BlockSize}指令块解码 x{Iterations}: {perOp:F0} ns/块 ({perOp / BlockSize:F0} ns/指令)");
        }
    }
}
