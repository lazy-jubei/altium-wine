#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdint.h>
static int failures;
static uint32_t expected[16][16];
static int verify(ID3D11DeviceContext *context, ID3D11Texture2D *texture, ID3D11Texture2D *staging, const char *label)
{
    D3D11_MAPPED_SUBRESOURCE m;
    unsigned bad = 0;
    HRESULT hr;
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)texture);
    hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m);
    if (FAILED(hr))
    {
        printf("FAIL %s map=%#lx\n", label, hr);
        ++failures;
        return 0;
    }
    for (unsigned y = 0; y < 16; ++y)
        for (unsigned x = 0; x < 16; ++x)
        {
            uint32_t v = ((uint32_t *)((BYTE *)m.pData + y * m.RowPitch))[x] & 0xffffff;
            if (v != expected[y][x])
            {
                if (bad < 3)
                    printf("%s pixel %u,%u got=%06x expected=%06x\n", label, x, y, v, expected[y][x]);
                ++bad;
            }
        }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    printf("%s: %u/256 bad pixels\n", label, bad);
    failures += !!bad;
    return !bad;
}
int main(void)
{
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *texture = NULL, *staging = NULL;
    IDXGISurface1 *surface = NULL;
    D3D11_TEXTURE2D_DESC desc = { 0 };
    HRESULT hr;
    HDC dc;
    D3D_FEATURE_LEVEL level;
    int rc = 2;
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
        D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr))
    {
        printf("Device failed %#lx\n", hr);
        goto done;
    }
    desc.Width = desc.Height = 16;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_GDI_COMPATIBLE;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture);
    if (FAILED(hr))
    {
        printf("Texture failed %#lx\n", hr);
        goto done;
    }
    hr = ID3D11Texture2D_QueryInterface(texture, &IID_IDXGISurface1, (void **)&surface);
    if (FAILED(hr))
        goto done;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.BindFlags = desc.MiscFlags = 0;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    if (FAILED(hr))
        goto done;
    hr = IDXGISurface1_GetDC(surface, TRUE, &dc);
    if (FAILED(hr))
        goto done;
    for (int y = 0; y < 16; ++y)
    {
        unsigned r = 10 + y * 7, g = 40 + y * 3, b = 90 + y * 2;
        RECT row = { 0, y, 16, y + 1 };
        HBRUSH brush = CreateSolidBrush(RGB(r, g, b));
        FillRect(dc, &row, brush);
        DeleteObject(brush);
        for (int x = 0; x < 16; ++x)
            expected[y][x] = (r << 16) | (g << 8) | b;
    }
    hr = IDXGISurface1_ReleaseDC(surface, NULL);
    if (FAILED(hr))
        goto done;
    verify(context, texture, staging, "full upload");
    RECT rects[] = { { 4, 8, 12, 12 }, { 0, 13, 16, 16 }, { 3, 2, 9, 5 } };
    for (unsigned i = 0; i < sizeof(rects) / sizeof(rects[0]); ++i)
    {
        RECT rect = rects[i];
        unsigned r = 230 - i * 20, g = 20 + i * 40, b = 150;
        HBRUSH brush;
        hr = IDXGISurface1_GetDC(surface, FALSE, &dc);
        if (FAILED(hr))
            goto done;
        brush = CreateSolidBrush(RGB(r, g, b));
        FillRect(dc, &rect, brush);
        DeleteObject(brush);
        hr = IDXGISurface1_ReleaseDC(surface, &rect);
        if (FAILED(hr))
            goto done;
        for (int y = rect.top; y < rect.bottom; ++y)
            for (int x = rect.left; x < rect.right; ++x)
                expected[y][x] = (r << 16) | (g << 8) | b;
        char label[64];
        snprintf(label, sizeof(label), "partial upload %u top=%ld", i, rect.top);
        verify(context, texture, staging, label);
    }
    rc = failures ? 1 : 0;
done:
    if (surface)
        IDXGISurface1_Release(surface);
    if (staging)
        ID3D11Texture2D_Release(staging);
    if (texture)
        ID3D11Texture2D_Release(texture);
    if (context)
        ID3D11DeviceContext_Release(context);
    if (device)
        ID3D11Device_Release(device);
    if (rc == 2)
        printf("API failure %#lx\n", hr);
    return rc;
}
