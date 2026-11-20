// SPDX-License-Identifier: LGPL-2.1-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

typedef id<MTLRenderPipelineState> (*MeshPipeline)(
    id, SEL, MTLMeshRenderPipelineDescriptor *, MTLPipelineOption,
    MTLRenderPipelineReflection **, NSError **);
static MeshPipeline create_mesh_pipeline;

static BOOL is_altium_grid(MTLMeshRenderPipelineDescriptor *descriptor)
{
    return [descriptor.objectFunction.name hasPrefix:@"vsgs_f12ecd97_"] &&
           [descriptor.meshFunction.name hasPrefix:@"gs_124b811c_"] &&
           [descriptor.fragmentFunction.name hasPrefix:@"ps_8b7ef9cd_"];
}

static id<MTLRenderPipelineState> create_altium_mesh_pipeline(
    id device, SEL selector, MTLMeshRenderPipelineDescriptor *descriptor, MTLPipelineOption options,
    MTLRenderPipelineReflection **reflection, NSError **caller_error)
{
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline =
        create_mesh_pipeline(device, selector, descriptor, options, reflection, &error);
    if (!pipeline && is_altium_grid(descriptor))
    {
        // The Radeon driver can reject the grid pipeline during early initialization.
        MTLMeshRenderPipelineDescriptor *retry = [descriptor copy];
        error = nil;
        pipeline = create_mesh_pipeline(device, selector, retry, options, reflection, &error);
        [retry release];
    }
    if (caller_error) *caller_error = pipeline ? nil : error;
    return pipeline;
}

__attribute__((constructor))
static void initialize_metal(void)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return;

        Class device_class = object_getClass(device);
        SEL selector = @selector(newRenderPipelineStateWithMeshDescriptor:options:reflection:error:);
        Method method = class_getInstanceMethod(device_class, selector);
        if (method)
        {
            // Keep the override on the concrete device class if the method was inherited.
            create_mesh_pipeline = (MeshPipeline)method_getImplementation(method);
            if (!class_addMethod(device_class, selector, (IMP)create_altium_mesh_pipeline,
                                 method_getTypeEncoding(method)))
                method_setImplementation(method, (IMP)create_altium_mesh_pipeline);
        }
        [device release];
    }
}
