using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: AssemblyVersion("1.0.0.0")]

namespace LocalDiagnostics
{
    public static class RoutingHandoffGuard
    {
        private const int Begin = 368;
        private const int End = 369;
        private const int UnknownProcess = 0;
        private const int SingleTrack = 1;
        private const int DifferentialPair = 3;

        private sealed class DocumentState
        {
            public int ActiveProcess;
            public bool SingleTrackEndedWithoutIdentity;
            public bool ExpectRedundantSingleTrackEnd;
        }

        private static readonly ConditionalWeakTable<object, DocumentState> States =
            new ConditionalWeakTable<object, DocumentState>();

        [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern void OutputDebugStringW(string message);

        public static bool ShouldSkip(object document, int notification, int process)
        {
            if (document == null || (notification != Begin && notification != End))
                return false;

            var state = States.GetValue(document, key => new DocumentState());
            if (notification == Begin)
            {
                state.ExpectRedundantSingleTrackEnd = process == DifferentialPair &&
                    state.SingleTrackEndedWithoutIdentity;
                state.ActiveProcess = process;
                state.SingleTrackEndedWithoutIdentity = false;
                return false;
            }

            if (process == SingleTrack && state.ActiveProcess == DifferentialPair &&
                state.ExpectRedundantSingleTrackEnd)
            {
                state.ExpectRedundantSingleTrackEnd = false;
                OutputDebugStringW("ROUTING-TRACE skipped duplicate single-track end");
                return true;
            }

            state.SingleTrackEndedWithoutIdentity = state.ActiveProcess == SingleTrack &&
                process == UnknownProcess;
            state.ExpectRedundantSingleTrackEnd = false;
            state.ActiveProcess = UnknownProcess;
            return false;
        }
    }
}
