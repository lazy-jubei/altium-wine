// GPU readback comparison for the default Direct2D cache and ordered batch.
// Build with x86_64-w64-mingw32-g++ -O2 -static -ld3d11 -ld2d1 -ldwrite -ldxgi -ldxguid -luser32.
#include <windows.h>
#include <d3d11.h>
#include <d2d1.h>
#include <d2d1helper.h>
#include <dwrite.h>
#include <dxgi.h>
#include <cstdio>
#include <cstdint>
#include <cmath>
int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3)
        return 2;

    ID3D11Device *d = nullptr;
    ID3D11DeviceContext *c = nullptr;
    ID3D11Texture2D *t = nullptr, *staging = nullptr;
    IDXGISurface *surface = nullptr;
    ID2D1Factory *factory = nullptr;
    ID2D1RenderTarget *rt = nullptr;
    ID2D1SolidColorBrush *brush = nullptr;
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &d, &level, &c);
    if (FAILED(hr))
    {
        printf("device %#lx\n", hr);
        return 3;
    }
    printf("device feature level %#x\n", level);
    D3D11_TEXTURE2D_DESC desc = { };
    desc.Width = desc.Height = 256;
    desc.ArraySize = desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    hr = d->CreateTexture2D(&desc, nullptr, &t);
    if (FAILED(hr))
        return 4;
    hr = t->QueryInterface(__uuidof(IDXGISurface), (void **)&surface);
    if (FAILED(hr))
        return 4;
    hr = D2D1CreateFactory((argc == 3 ? D2D1_FACTORY_TYPE_MULTI_THREADED : D2D1_FACTORY_TYPE_SINGLE_THREADED),
        __uuidof(ID2D1Factory), nullptr, (void **)&factory);
    if (FAILED(hr))
        return 4;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(desc.Format, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    hr = factory->CreateDxgiSurfaceRenderTarget(surface, &props, &rt);
    if (FAILED(hr))
    {
        printf("target %#lx\n", hr);
        return 4;
    }
    hr = rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &brush);
    if (FAILED(hr))
        return 4;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.BindFlags = 0;
    hr = d->CreateTexture2D(&desc, nullptr, &staging);
    if (FAILED(hr))
        return 4;
    IDWriteFactory *dwrite = nullptr;
    IDWriteTextFormat *format = nullptr;
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown **)&dwrite);
    if (FAILED(hr))
        return 8;
    hr = dwrite->CreateTextFormat(L"Arial", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, 13.25f, L"en-us", &format);
    if (FAILED(hr))
        return 8;
    FILE *f = fopen(argv[1], "wb");
    if (!f)
        return 5;
    for (int test = 0; test < 16; ++test)
    {
        D2D1_MATRIX_3X2_F m = D2D1::Matrix3x2F::Identity();
        if (test % 4 == 1)
            m = D2D1::Matrix3x2F::Rotation(17, D2D1::Point2F(128, 128));
        if (test % 4 == 2)
            m = D2D1::Matrix3x2F::Scale(0.7f, 1.1f) * D2D1::Matrix3x2F::Translation(23.25f, -3.5f);
        if (test % 4 == 3)
            m = D2D1::Matrix3x2F(-0.9f, 0.2f, 0.1f, 0.8f, 240, 10);
        rt->BeginDraw();
        rt->SetTransform(D2D1::Matrix3x2F::Identity());
        rt->Clear(D2D1::ColorF(1, 1, 1, 1));
        rt->SetTransform(m);
        rt->SetAntialiasMode(test < 8 ? D2D1_ANTIALIAS_MODE_ALIASED : D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        rt->SetDpi(test >= 4 && test < 8 ? 144 : 96, test >= 4 && test < 8 ? 144 : 96);
        if (test & 1)
            rt->PushAxisAlignedClip(D2D1::RectF(17, 23, 218, 211), D2D1_ANTIALIAS_MODE_ALIASED);
        for (int i = 0; i < 80; ++i)
        {
            float x = 7.25f + (i % 10) * 23.0f, y = 9.5f + (i / 10) * 28.0f;
            brush->SetColor(
                D2D1::ColorF((i % 3) * 0.4f, ((i + 1) % 4) * 0.2f, ((i + 2) % 5) * 0.15f, i % 3 == 1 ? 0.5f : 1.0f));
            auto p0 = D2D1::Point2F(x, y), p1 = D2D1::Point2F(x + (i % 2 ? -17.5f : 15.25f), y + (i % 3 ? 0 : 12.75f));
            rt->DrawLine(p0, p1, brush, (i % 4) * 0.5f + 0.5f);
            rt->DrawRectangle(D2D1::RectF(x + 2, y + 2, x + 18, y + 15), brush, 0.75f + (i % 3));
            rt->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(x + 6, y + 6), 3.25f, 4.5f), brush, 1.0f);
            rt->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x + 14, y + 10), 2.25f, 2.75f), brush);
        }
        if (test >= 12)
        {
            ID2D1DrawingStateBlock *state = nullptr;
            hr = factory->CreateDrawingStateBlock(&state);
            if (FAILED(hr))
                return 10;
            rt->SaveDrawingState(state);
            for (int n = 0; n < 12000; ++n)
            {
                if (n % 19 == 0)
                    rt->SetTransform(D2D1::Matrix3x2F::Translation((n % 3) * 0.25f, -(n % 7) * 0.125f));
                if (n % 29 == 0)
                    rt->SetDpi(n % 2 ? 96 : 144, n % 2 ? 96 : 144);
                if (n % 37 == 0)
                    rt->SetAntialiasMode(n % 2 ? D2D1_ANTIALIAS_MODE_ALIASED : D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                brush->SetOpacity(n % 2 ? 0.45f : 1.0f);
                brush->SetColor(D2D1::ColorF((n % 5) * 0.2f, (n % 3) * 0.3f, (n % 7) * 0.13f, n % 2 ? 0.5f : 1));
                float x = 17.25f + (n % 151), y = 23.5f + (n % 137);
                if (test == 12)
                    rt->FillRectangle(D2D1::RectF(x, y, x + 7.125f, y + 9.25f), brush);
                if (test == 13)
                    rt->DrawLine(D2D1::Point2F(x, y), D2D1::Point2F(x + (n % 577) * 0.125f, y + (n % 569) * 0.125f),
                        brush, 1.25f);
                if (test == 14)
                {
                    rt->PushAxisAlignedClip(D2D1::RectF(10, 10, 210, 210), D2D1_ANTIALIAS_MODE_ALIASED);
                    rt->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x, y), 9.125f, 7.25f), brush);
                    rt->PopAxisAlignedClip();
                }
                if (test == 15)
                {
                    rt->DrawRectangle(D2D1::RectF(x, y, x + 3.125f + (n % 1597) * 0.125f, y + 7.25f + (n % 173) * 0.125f), brush, 0.75f);
                    if (n % 113 == 0)
                    {
                        hr = rt->Flush();
                        if (FAILED(hr))
                            return 11;
                    }
                }
            }
            rt->RestoreDrawingState(state);
            state->Release();
            brush->SetOpacity(1.0f);
        }
        brush->SetColor(D2D1::ColorF(0.1f, 0.2f, 0.3f, 1));
        const wchar_t label[] = L"STM32U595 10k 0201 AD5689R ABC 0123456789";
        for (int j = 0; j < 4; ++j)
            rt->DrawText(label, (UINT32)(sizeof(label) / sizeof(label[0]) - 1), format,
                D2D1::RectF(13.5f, 125.25f + j * 24, 245, 210.75f + j * 24), brush,
                j % 2 ? D2D1_DRAW_TEXT_OPTIONS_CLIP : D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
        if (test == 3)
            rt->Clear(D2D1::ColorF(0.8f, 0.9f, 1, 1));
        if (test == 5)
        {
            hr = rt->Flush();
            if (FAILED(hr))
                return 9;
        }
        if (test & 1)
            rt->PopAxisAlignedClip();
        hr = rt->EndDraw();
        if (FAILED(hr))
        {
            printf("EndDraw %#lx\n", hr);
            return 6;
        }
        c->CopyResource(staging, t);
        D3D11_MAPPED_SUBRESOURCE map;
        hr = c->Map(staging, 0, D3D11_MAP_READ, 0, &map);
        if (FAILED(hr))
            return 7;
        uint64_t hash = 1469598103934665603ull;
        for (unsigned y = 0; y < 256; ++y)
        {
            auto p = (const uint8_t *)map.pData + y * map.RowPitch;
            fwrite(p, 1, 256 * 4, f);
            for (unsigned x = 0; x < 256 * 4; ++x)
                hash = (hash ^ p[x]) * 1099511628211ull;
        }
        c->Unmap(staging, 0);
        printf("case %d hash=%016llx\n", test, (unsigned long long)hash);
    }
    fclose(f);
    format->Release();
    dwrite->Release();
    brush->Release();
    rt->Release();
    factory->Release();
    surface->Release();
    staging->Release();
    t->Release();
    c->Release();
    d->Release();
    return 0;
}
