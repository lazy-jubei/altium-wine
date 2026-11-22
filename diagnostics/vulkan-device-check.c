/* Vulkan loader/device regression probe. LGPL-2.1-or-later.
 * Build with a Windows C compiler; no Vulkan SDK is needed. These are the
 * Vulkan 1.0 application/instance structures and dispatchable handle ABI.
 * Loads Wine's normal Vulkan DLL and requires an enumerated physical device.
 */
#include <windows.h>
#include <stdio.h>
typedef struct {unsigned type; const void *next; const char *name; unsigned version; const char *engine; unsigned eversion; unsigned api;} app_info;
typedef struct {unsigned type; const void *next; unsigned flags; const app_info *app; unsigned layerCount; const char *const *layers; unsigned extCount; const char *const *extensions;} instance_info;
int main(void){
 HMODULE m=LoadLibraryW(L"vulkan-1.dll"); if(!m){printf("load error=%lu\n",GetLastError());return 2;}
 int (WINAPI *create)(const instance_info*,void*,void**)= (void*)GetProcAddress(m,"vkCreateInstance");
 int (WINAPI *enumerate)(void*,unsigned*,void*)=(void*)GetProcAddress(m,"vkEnumeratePhysicalDevices");
 void (WINAPI *destroy)(void*,void*)=(void*)GetProcAddress(m,"vkDestroyInstance");
 void *instance=NULL;app_info app={0,NULL,"Wine Vulkan regression",0,NULL,0,1u<<22};instance_info info={1,NULL,0,&app,0,NULL,0,NULL};
 if(!create||!enumerate||!destroy)return 3;
 int result=create(&info,NULL,&instance);printf("vkCreateInstance=%d instance=%p\n",result,instance);if(result)return 4;
 unsigned count=0;result=enumerate(instance,&count,NULL);printf("vkEnumeratePhysicalDevices=%d devices=%u\n",result,count);destroy(instance,NULL);return result||!count;
}
