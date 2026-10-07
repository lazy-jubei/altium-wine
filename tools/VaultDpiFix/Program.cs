using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Mono.Cecil;
using Mono.Cecil.Cil;

class Program
{
    // AD17.1 Vault assemblies. Never rewrite an unknown build.
    const string CommonHash = "b0e6b63f230ffed2d357c0fe6cf9d8a6459272e194ee9a024e4395540d86dac6";
    const string SearchHash = "30babb0f4101420ff2abfa300a9ecbfeb12717e2ffb7d9906e13ce2317af5421";
    const string OriginalHash = "ffae946a8a0a154c1fd244b9662638a12ce08d05d7caf8d72349d3993c69190c";

    static MethodDefinition Initializer(ModuleDefinition module, string type) =>
        module.Types.Single(t => t.FullName == "VaultExplorer.Controls." + type)
            .Methods.Single(m => m.Name == "InitializeComponent");

    static Instruction Call(MethodDefinition method, string name) =>
        method.Body.Instructions.Single(i => i.Operand is MethodReference reference && reference.Name == name);

    static string[] Instructions(MethodDefinition method) => method.HasBody
        ? method.Body.Instructions.Select(i => i.OpCode + " " + i.Operand).ToArray()
        : new string[0];

    static void ExpandBranches(ModuleDefinition module)
    {
        foreach (var method in module.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody &&
            ((m.Name == "InitializeComponent" && new[] { "VaultExplorer.Controls.ComponentHeader", "VaultExplorer.Controls.MessagePanel", "VaultExplorer.Controls.Views.AspectViewSummaryItem", "Plugins.AdvancedSearch.Views.GenericSearchView" }.Contains(m.DeclaringType.FullName)) ||
             (m.Name == "UpdateSummaryTab" && m.DeclaringType.FullName == "VaultExplorer.Controls.Views.RevisionDetailsView") ||
             (m.Name == "LoadUserDefinedBrowseItemsOptions" && m.DeclaringType.FullName == "VaultExplorer.Controls.Views.FolderDetailsView") ||
             (m.Name == "DecodeVaultParamName" && m.DeclaringType.FullName == "VaultExplorer.Common.Utils.Helpers"))))
            foreach (var instruction in method.Body.Instructions)
                if (instruction.OpCode.OperandType == OperandType.ShortInlineBrTarget) {
                    var name = instruction.OpCode.Name.Substring(0, instruction.OpCode.Name.Length - 2);
                    instruction.OpCode = (OpCode)typeof(OpCodes).GetFields().Single(f =>
                        f.FieldType == typeof(OpCode) && ((OpCode)f.GetValue(null)).Name == name).GetValue(null);
                }
    }

    static void FixSearch(ModuleDefinition module)
    {
        if (module.Assembly.Name.HasPublicKey) throw new InvalidOperationException("Signed Vault assembly.");
        var type = module.Types.Single(t => t.FullName == "Plugins.AdvancedSearch.Views.GenericSearchView");
        var method = type.Methods.Single(m => m.Name == "InitializeComponent");
        var mode = Call(method, "set_AutoScaleMode");
        var dimensions = Call(method, "set_AutoScaleDimensions");
        if (mode.Previous.OpCode != OpCodes.Ldc_I4_1 ||
            (float)dimensions.Previous.Previous.Operand != 13f ||
            (float)dimensions.Previous.Previous.Previous.Operand != 6f)
            throw new InvalidOperationException("Unexpected search layout policy.");
        mode.Previous.OpCode = OpCodes.Ldc_I4_2;
        dimensions.Previous.Previous.Operand = dimensions.Previous.Previous.Previous.Operand = 96f;
        // One parent owns scaling. Inherited SplitContainer scaling otherwise
        // repeatedly enlarges padding and consumes the results viewport.
        var il = method.Body.GetILProcessor();
        var next = mode.Next;
        foreach (var field in type.Fields.Where(f => f.FieldType.FullName == "System.Windows.Forms.SplitContainer"))
            foreach (var instruction in new[] { Instruction.Create(OpCodes.Ldarg_0),
                Instruction.Create(OpCodes.Ldfld, field), Instruction.Create(OpCodes.Ldc_I4_0),
                Instruction.Create(OpCodes.Callvirt, (MethodReference)mode.Operand) })
                il.InsertBefore(next, instruction);
    }

    static void FixShared(ModuleDefinition module)
    {
        var header = Initializer(module, "ComponentHeader");
        var message = Initializer(module, "MessagePanel");
        var headerMode = Call(header, "set_AutoScaleMode").Previous;
        var messageMode = Call(message, "set_AutoScaleMode").Previous;
        if (module.Assembly.Name.HasPublicKey || headerMode.OpCode != OpCodes.Ldc_I4_0 || messageMode.OpCode != OpCodes.Ldc_I4_3)
            throw new InvalidOperationException("Unexpected layout policy; no changes made.");

        // The header already has designer font dimensions (6,13), but disables scaling.
        headerMode.OpCode = OpCodes.Ldc_I4_1;
        var sizeConstructor = (MethodReference)header.Body.Instructions.Single(i =>
            i.OpCode == OpCodes.Newobj && ((MethodReference)i.Operand).DeclaringType.FullName == "System.Drawing.SizeF").Operand;
        var dimensions = (MethodReference)Call(header, "set_AutoScaleDimensions").Operand;
        // Dynamically created controls cannot inherit their designer coordinate system.
        // Declare 96 DPI explicitly; keep the original point-size fonts.
        foreach (var control in new[] { message, Initializer(module, "Views.AspectViewSummaryItem") })
        {
            var mode = Call(control, "set_AutoScaleMode").Previous;
            if (mode.OpCode != OpCodes.Ldc_I4_3) throw new InvalidOperationException("Unexpected child layout policy.");
            mode.OpCode = OpCodes.Ldc_I4_2;
            var il = control.Body.GetILProcessor();
            foreach (var instruction in new[] {
                Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldc_R4, 96f),
                Instruction.Create(OpCodes.Ldc_R4, 96f), Instruction.Create(OpCodes.Newobj, sizeConstructor),
                Instruction.Create(OpCodes.Call, dimensions) })
                il.InsertBefore(mode.Previous, instruction);
        }
        // The dynamically built list otherwise clamps scaled controls back to 49 pixels.
        var summary = module.Types.Single(t => t.FullName == "VaultExplorer.Controls.Views.RevisionDetailsView")
            .Methods.Single(m => m.Name == "UpdateSummaryTab");
        var constructor = module.Types.Single(t => t.FullName == "VaultExplorer.Controls.Views.AspectViewSummaryItem")
            .Methods.Single(m => m.IsConstructor && !m.IsStatic);
        var getDpi = (MethodReference)Call(constructor, "GetDPI").Operand;
        var dpiY = (MethodReference)Call(constructor, "get_Item1").Operand;
        var heights = summary.Body.Instructions.Where(i => i.OpCode == OpCodes.Ldc_I4_S && (sbyte)i.Operand == 49).ToArray();
        if (heights.Length != 2) throw new InvalidOperationException("Unexpected summary row constraints.");
        foreach (var height in heights)
        {
            var il = summary.Body.GetILProcessor();
            var next = height.Next;
            foreach (var instruction in new[] {
                Instruction.Create(OpCodes.Conv_R4), Instruction.Create(OpCodes.Ldarg_0),
                Instruction.Create(OpCodes.Call, getDpi), Instruction.Create(OpCodes.Callvirt, dpiY),
                Instruction.Create(OpCodes.Mul), Instruction.Create(OpCodes.Ldc_R4, 96f),
                Instruction.Create(OpCodes.Div), Instruction.Create(OpCodes.Conv_I4) })
                il.InsertBefore(next, instruction);
        }
        // AD17 selects "Load all pages" when constructing every search view.
        // Leave its existing pagination enabled instead of importing the entire
        // modern Vault before allowing the user to interact with the results.
        var settings = module.Types.Single(t => t.FullName == "VaultExplorer.Controls.ButtonSettingsFolder")
            .Methods.Single(m => m.Name == "FillContextMenuSettings");
        var checkAll = Call(settings, "CheckItem");
        if (checkAll.Previous.OpCode != OpCodes.Ldloc_0 || checkAll.Next.OpCode != OpCodes.Pop)
            throw new InvalidOperationException("Unexpected default pagination policy.");
        foreach (var instruction in new[] { checkAll.Previous, checkAll, checkAll.Next })
        {
            instruction.OpCode = OpCodes.Nop;
            instruction.Operand = null;
        }
        // Missing saved options also re-enable all pages for newer Vault types.
        // Keep explicitly saved choices; remove only that implicit default.
        var loadOptions = module.Types.Single(t => t.FullName == "VaultExplorer.Controls.Views.FolderDetailsView")
            .Methods.Single(m => m.Name == "LoadUserDefinedBrowseItemsOptions");
        var defaultAll = loadOptions.Body.Instructions.Single(i => i.Offset == 0xaf);
        var nextOption = loadOptions.Body.Instructions.Single(i => i.Offset == 0xe3);
        if (defaultAll.OpCode != OpCodes.Ldloc_3 || nextOption.OpCode != OpCodes.Ldloc_2)
            throw new InvalidOperationException("Unexpected saved pagination policy.");
        defaultAll.OpCode = OpCodes.Br;
        defaultAll.Operand = nextOption;
    }

    static void FixDecoder(ModuleDefinition module)
    {
        var method = module.Types.Single(t => t.FullName == "VaultExplorer.Common.Utils.Helpers")
            .Methods.Single(m => m.Name == "DecodeVaultParamName");
        var parse = Call(method, "TryParse");
        var substring = Call(method, "Substring");
        var next = method.Body.Instructions.Single(i => i.Offset == 0x60);
        var length = (MethodReference)method.Body.Instructions.Last(i => i.Operand is MethodReference r &&
            r.Name == "get_Length" && r.DeclaringType.FullName == "System.Text.StringBuilder").Operand;
        var before = substring.Previous.Previous.Previous.Previous.Previous.Previous;
        if (parse.Next.OpCode != OpCodes.Pop || before.OpCode != OpCodes.Ldloc_0 || next.OpCode != OpCodes.Ldloc_1)
            throw new InvalidOperationException("Unexpected parameter decoder.");
        var il = method.Body.GetILProcessor();
        // A literal or truncated underscore is not an encoded byte. Preserve it.
        foreach (var instruction in new[] { Instruction.Create(OpCodes.Ldloc_1),
            Instruction.Create(OpCodes.Ldc_I4_2), Instruction.Create(OpCodes.Add),
            Instruction.Create(OpCodes.Ldloc_0), Instruction.Create(OpCodes.Callvirt, length),
            Instruction.Create(OpCodes.Bge, next) })
            il.InsertBefore(before, instruction);
        parse.Next.OpCode = OpCodes.Brfalse;
        parse.Next.Operand = next;
    }

    static int Main(string[] args)
    {
        string output = null;
        bool created = false;
        try
        {
            if (args.Length < 2 || args.Length > 3) throw new ArgumentException("Usage: VaultDpiFix.exe ORIGINAL_DLL OUTPUT_DLL [ALTIUM_SYSTEM_DIRECTORY]");
            var input = Path.GetFullPath(args[0]);
            output = Path.GetFullPath(args[1]);
            if (input.Equals(output, StringComparison.OrdinalIgnoreCase) || File.Exists(output))
                throw new InvalidOperationException("Choose a new output file; the original is never overwritten.");
            string hash;
            using (var sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(input))).Replace("-", "").ToLowerInvariant();
            if (hash != OriginalHash && hash != SearchHash && hash != CommonHash)
                throw new InvalidOperationException("Unrecognized Vault assembly; no changes made.");
            bool search = hash == SearchHash, common = hash == CommonHash;
            using (var resolver = new DefaultAssemblyResolver())
            {
                var system = args.Length == 3 ? Path.GetFullPath(args[2]) : Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Altium", "AD17", "System");
                resolver.AddSearchDirectory(system);
                resolver.AddSearchDirectory(Path.Combine(system, "DotNet", "DevExpress.14.2.7"));
                resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location));

                using (var module = ModuleDefinition.ReadModule(input, new ReaderParameters { AssemblyResolver = resolver }))
                {
                    if (common) FixDecoder(module);
                    else if (search) FixSearch(module);
                    else FixShared(module);
                    ExpandBranches(module);
                    using (var stream = new FileStream(output, FileMode.CreateNew, FileAccess.Write))
                    {
                        created = true;
                        module.Write(stream);
                    }
                }

                // Metadata tokens can move when writing; compare resolved IL for every method.
                using (var before = ModuleDefinition.ReadModule(input))
                using (var after = ModuleDefinition.ReadModule(output))
                {
                    var original = before.GetTypes().SelectMany(t => t.Methods).ToDictionary(m => m.FullName);
                    var patched = after.GetTypes().SelectMany(t => t.Methods).ToDictionary(m => m.FullName);
                    var changed = original.Keys.Where(k => !Instructions(original[k]).SequenceEqual(Instructions(patched[k]))).ToArray();
                    if (original.Count != patched.Count || (common ?
                        changed.Length != 1 || !changed[0].Contains("Helpers::DecodeVaultParamName(") : search ?
                        changed.Length != 1 || !changed[0].Contains("GenericSearchView::InitializeComponent(") :
                        changed.Length != 6 ||
                        !changed.Contains(Initializer(before, "ComponentHeader").FullName) ||
                        !changed.Contains(Initializer(before, "MessagePanel").FullName) ||
                        !changed.Contains(Initializer(before, "Views.AspectViewSummaryItem").FullName) ||
                        !changed.Any(k => k.Contains("RevisionDetailsView::UpdateSummaryTab(")) ||
                        !changed.Any(k => k.Contains("ButtonSettingsFolder::FillContextMenuSettings(")) ||
                        !changed.Any(k => k.Contains("FolderDetailsView::LoadUserDefinedBrowseItemsOptions("))))
                        throw new InvalidOperationException("Unexpected method changes in output.");
                    Console.WriteLine("Fixed Vault compatibility; verified {0} methods, with {1} methods changed.", original.Count, changed.Length);
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (created) File.Delete(output);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
