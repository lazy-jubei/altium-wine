using System;using System.IO;using System.Reflection;
class Program {
 static int Main(string[] args) {
  if(args.Length<1||args.Length>2){Console.Error.WriteLine("Usage: VaultCodecCheck.exe VAULT_COMMON_DLL [ALTIUM_SYSTEM_DIRECTORY]");return 2;}
  string system=args.Length==2?args[1]:Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),"Altium","AD17","System");
  AppDomain.CurrentDomain.AssemblyResolve+=(s,e)=>{
   foreach(var dir in new[]{Path.GetDirectoryName(Path.GetFullPath(args[0])),system,Path.Combine(system,"DotNet","DevExpress.14.2.7")}){var path=Path.Combine(dir,new AssemblyName(e.Name).Name+".dll");if(File.Exists(path))return Assembly.LoadFrom(path);}return null;
  };
  var type=Assembly.LoadFrom(args[0]).GetType("VaultExplorer.Common.Utils.Helpers");var decode=type.GetMethod("DecodeVaultParamName",BindingFlags.Static|BindingFlags.Public|BindingFlags.NonPublic);
  string[,] cases={{"",""},{"Name","Name"},{"_","_"},{"Name_","Name_"},{"Name_A","Name_A"},{"Name_GG","Name_GG"},{"Name_0G","Name_0G"},{"_20"," "},{"Part_20Number","Part Number"},{"_5F","_"},{"A_5F_B","A__B"},{"NameDD420E8DDD8B445E911A0601BB2B6D53","Name"},{"NameC623975962814A5FAAD7FA1CD85DA0DB","Name"}};
  int failures=0;for(int i=0;i<cases.GetLength(0);i++)try{var actual=(string)decode.Invoke(null,new object[]{cases[i,0]});if(actual!=cases[i,1]){failures++;Console.WriteLine("FAIL "+cases[i,0]+" -> "+actual);}}catch(Exception e){failures++;Console.WriteLine("FAIL "+cases[i,0]+" "+e.GetBaseException().Message);}
  Console.WriteLine((cases.GetLength(0)-failures)+"/"+cases.GetLength(0)+" parameter decode cases passed");return failures==0?0:1;
 }
}
