using System;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class PatchRoutingProvider
{
    private static MethodDefinition AddDebugOutput(ModuleDefinition module)
    {
        var type = new TypeDefinition("LocalDiagnostics", "RoutingTrace",
            TypeAttributes.NotPublic | TypeAttributes.Abstract | TypeAttributes.Sealed,
            module.TypeSystem.Object);
        module.Types.Add(type);
        var kernel = module.ModuleReferences.FirstOrDefault(reference =>
            string.Equals(reference.Name, "kernel32.dll", StringComparison.OrdinalIgnoreCase));
        if (kernel == null)
        {
            kernel = new ModuleReference("kernel32.dll");
            module.ModuleReferences.Add(kernel);
        }

        var output = new MethodDefinition("Write",
            MethodAttributes.Assembly | MethodAttributes.Static | MethodAttributes.PInvokeImpl,
            module.TypeSystem.Void);
        output.Parameters.Add(new ParameterDefinition("line", ParameterAttributes.None, module.TypeSystem.String));
        output.ImplAttributes = MethodImplAttributes.PreserveSig;
        output.PInvokeInfo = new PInvokeInfo(
            PInvokeAttributes.NoMangle | PInvokeAttributes.CharSetUnicode | PInvokeAttributes.CallConvWinapi,
            "OutputDebugStringW", kernel);
        type.Methods.Add(output);
        return output;
    }

    private static void GuardEndNotification(ModuleDefinition module, MethodDefinition output)
    {
        var provider = module.Types.Single(type => type.Name == "PcbPropertyProvider");
        var target = provider.Methods.Single(method => method.Name == "ProcessNotificationInteractiveProcess");
        var members = module.GetMemberReferences().OfType<MethodReference>().ToList();
        var getCode = members.Single(member =>
            member.DeclaringType.Name == "IADInteractiveProcessNotification" && member.Name == "GetCode");
        var getWorkingObject = members.Single(member =>
            member.DeclaringType.Name == "IADInteractiveProcessNotification" && member.Name == "GetState_WorkingObject");
        var getProcessId = members.Single(member =>
            member.DeclaringType.FullName == "RT_InteractiveProcess.IInteractiveProcess" && member.Name == "GetState_ProcessId");
        if (target.Parameters[0].ParameterType.FullName != getCode.DeclaringType.FullName ||
            target.Parameters[1].ParameterType.IsValueType)
            throw new InvalidOperationException("Unexpected notification method parameters.");

        var guardAssembly = new AssemblyNameReference("RoutingHandoffGuard", new Version(1, 0, 0, 0));
        module.AssemblyReferences.Add(guardAssembly);
        var guardType = new TypeReference("LocalDiagnostics", "RoutingHandoffGuard", module, guardAssembly);
        var shouldSkip = new MethodReference("ShouldSkip", module.TypeSystem.Boolean, guardType);
        shouldSkip.Parameters.Add(new ParameterDefinition(module.TypeSystem.Object));
        shouldSkip.Parameters.Add(new ParameterDefinition(module.TypeSystem.Int32));
        shouldSkip.Parameters.Add(new ParameterDefinition(module.TypeSystem.Int32));

        var observer = new MethodDefinition("ShouldSkipNotification",
            MethodAttributes.Assembly | MethodAttributes.Static, module.TypeSystem.Boolean);
        observer.Parameters.Add(new ParameterDefinition(target.Parameters[0].ParameterType));
        observer.Parameters.Add(new ParameterDefinition(target.Parameters[1].ParameterType));
        output.DeclaringType.Methods.Add(observer);
        observer.Body.InitLocals = true;
        var process = new VariableDefinition(getProcessId.DeclaringType);
        var code = new VariableDefinition(module.TypeSystem.Int32);
        var processId = new VariableDefinition(module.TypeSystem.Int32);
        var skip = new VariableDefinition(module.TypeSystem.Boolean);
        foreach (var local in new[] { process, code, processId, skip })
            observer.Body.Variables.Add(local);

        var il = observer.Body.GetILProcessor();
        var tryStart = il.Create(OpCodes.Ldarg_0);
        var readProcess = il.Create(OpCodes.Ldarg_0);
        var callGuard = il.Create(OpCodes.Ldarg_1);
        var failed = il.Create(OpCodes.Pop);
        var done = il.Create(OpCodes.Ldloc, skip);
        var runtime = module.AssemblyReferences.Single(reference => reference.Name == "System.Runtime");
        var exceptionType = new TypeReference("System", "Exception", module, runtime);

        il.Append(tryStart);
        il.Emit(OpCodes.Callvirt, getCode);
        il.Emit(OpCodes.Stloc, code);
        il.Emit(OpCodes.Ldloc, code);
        il.Emit(OpCodes.Ldc_I4, 368);
        il.Emit(OpCodes.Beq_S, readProcess);
        il.Emit(OpCodes.Ldloc, code);
        il.Emit(OpCodes.Ldc_I4, 369);
        il.Emit(OpCodes.Beq_S, readProcess);
        il.Emit(OpCodes.Leave_S, done);
        il.Append(readProcess);
        il.Emit(OpCodes.Callvirt, getWorkingObject);
        il.Emit(OpCodes.Isinst, getProcessId.DeclaringType);
        il.Emit(OpCodes.Stloc, process);
        il.Emit(OpCodes.Ldloc, process);
        il.Emit(OpCodes.Brfalse_S, callGuard);
        il.Emit(OpCodes.Ldloc, process);
        il.Emit(OpCodes.Callvirt, getProcessId);
        il.Emit(OpCodes.Stloc, processId);
        il.Append(callGuard);
        il.Emit(OpCodes.Ldloc, code);
        il.Emit(OpCodes.Ldloc, processId);
        il.Emit(OpCodes.Call, shouldSkip);
        il.Emit(OpCodes.Stloc, skip);
        il.Emit(OpCodes.Leave_S, done);
        il.Append(failed);
        il.Emit(OpCodes.Ldstr, "ROUTING-TRACE routing guard lookup failed");
        il.Emit(OpCodes.Call, output);
        il.Emit(OpCodes.Leave_S, done);
        il.Append(done);
        il.Emit(OpCodes.Ret);
        observer.Body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch) {
            CatchType = exceptionType, TryStart = tryStart, TryEnd = failed,
            HandlerStart = failed, HandlerEnd = done,
        });

        var body = target.Body.GetILProcessor();
        var first = target.Body.Instructions[0];
        body.InsertBefore(first, body.Create(OpCodes.Ldarg_1));
        body.InsertBefore(first, body.Create(OpCodes.Ldarg_2));
        body.InsertBefore(first, body.Create(OpCodes.Call, observer));
        body.InsertBefore(first, body.Create(OpCodes.Brfalse_S, first));
        body.InsertBefore(first, body.Create(OpCodes.Ret));
        Console.WriteLine("ROUTING-TRACE installed the PCB notification guard");
    }

    public static int Main(string[] args)
    {
        if (args.Length != 2 || args[0] == args[1])
            throw new ArgumentException("Provide separate input and output provider paths.");

        using (var module = ModuleDefinition.ReadModule(args[0]))
        {
            if (module.Assembly.Name.Name != "InteractiveProperties.Providers.PCB.DataModel" ||
                module.Assembly.Name.HasPublicKey ||
                module.Types.Any(type => type.Namespace == "LocalDiagnostics"))
                throw new InvalidOperationException("Unexpected original PCB provider.");

            GuardEndNotification(module, AddDebugOutput(module));
            module.Attributes |= ModuleAttributes.ILOnly;
            module.Write(args[1]);
        }
        return 0;
    }
}
