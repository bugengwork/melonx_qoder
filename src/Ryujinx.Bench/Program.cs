using System;

namespace Ryujinx.Bench
{
    internal static class Program
    {
        private static void Main()
        {
            Console.WriteLine("Ryujinx.Bench: ARMeilleure JIT micro-benchmark");
            Console.WriteLine();

            JitBench.Run();

            Console.WriteLine();
            Console.WriteLine("完成。");
        }
    }
}
