#include <windows.h>
#include <stdio.h>
#include <math.h>

struct startup_input { UINT version; void *callback; BOOL no_thread, no_codecs; };
typedef int (WINAPI *startup_fn)(ULONG_PTR *, const struct startup_input *, void *);
typedef int (WINAPI *family_fn)(const WCHAR *, void *, void **);
typedef int (WINAPI *font_fn)(void *, float, int, int, void **);
typedef int (WINAPI *bitmap_fn)(int, int, int, int, BYTE *, void **);
typedef int (WINAPI *resolution_fn)(void *, float, float);
typedef int (WINAPI *graphics_fn)(void *, void **);
typedef int (WINAPI *height_fn)(void *, void *, float *);
typedef int (WINAPI *dpi_height_fn)(void *, float, float *);
typedef int (WINAPI *page_unit_fn)(void *, int);
typedef int (WINAPI *delete_fn)(void *);
typedef void (WINAPI *shutdown_fn)(ULONG_PTR);

#define GET(var, name, type) type var = (type)GetProcAddress(module, name); if (!var) { printf("Missing %s\n", name); return 2; }
#define OK(call) do { int status = (call); if (status) { printf("%s => %d\n", #call, status); return 3; } } while (0)

int main(int argc, char **argv)
{
    HMODULE module;
    ULONG_PTR token;
    struct startup_input input = {1, NULL, FALSE, FALSE};
    void *family, *font, *image, *graphics;
    float height, expected;
    int unit, dpi, page, cases = 0, failures = 0;
    float calculated;
    BOOL late_aware = argc > 2;
    if (!late_aware) SetProcessDPIAware();
    module = LoadLibraryA(argc > 1 ? argv[1] : "gdiplus.dll");
    if (!module) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    GET(startup, "GdiplusStartup", startup_fn);
    GET(create_family, "GdipCreateFontFamilyFromName", family_fn);
    GET(create_font, "GdipCreateFont", font_fn);
    GET(create_bitmap, "GdipCreateBitmapFromScan0", bitmap_fn);
    GET(resolution, "GdipBitmapSetResolution", resolution_fn);
    GET(create_graphics, "GdipGetImageGraphicsContext", graphics_fn);
    GET(get_height, "GdipGetFontHeight", height_fn);
    GET(dpi_height, "GdipGetFontHeightGivenDPI", dpi_height_fn);
    GET(page_unit, "GdipSetPageUnit", page_unit_fn);
    GET(delete_graphics, "GdipDeleteGraphics", delete_fn);
    GET(delete_image, "GdipDisposeImage", delete_fn);
    GET(delete_font, "GdipDeleteFont", delete_fn);
    GET(delete_family, "GdipDeleteFontFamily", delete_fn);
    GET(shutdown, "GdiplusShutdown", shutdown_fn);
    OK(startup(&token, &input, NULL));
    OK(create_family(L"Arial", NULL, &family));
    if (late_aware) printf("late SetProcessDPIAware=%d\n", SetProcessDPIAware());
    for (unit = 2; unit <= 6; ++unit)
    {
        OK(create_font(family, 9.0, 0, unit, &font));
        for (dpi = 96; dpi <= 192; dpi += 48)
        {
            OK(create_bitmap(400, 200, 0, 0x26200a, NULL, &image));
            OK(resolution(image, dpi, dpi));
            OK(create_graphics(image, &graphics));
            for (page = 1; page <= 6; ++page)
            {
                OK(page_unit(graphics, page));
                OK(get_height(font, graphics, &height));
                OK(dpi_height(font, dpi, &expected));
                calculated = expected;
                if (unit != 2) switch (page)
                {
                    case 3: calculated *= 72.0f / dpi; break;
                    case 4: calculated /= dpi; break;
                    case 5: calculated *= 300.0f / dpi; break;
                    case 6: calculated *= 25.4f / dpi; break;
                }
                ++cases;
                if (fabsf(height - calculated) > 0.001f)
                {
                    printf("FAIL font_unit=%d page_unit=%d dpi=%d: %.6f expected %.6f\n",
                           unit, page, dpi, height, calculated);
                    ++failures;
                }
            }
            OK(delete_graphics(graphics));
            OK(delete_image(image));
        }
        OK(delete_font(font));
    }
    OK(delete_family(family));
    shutdown(token);
    printf("%d/%d font height cases passed\n", cases - failures, cases);
    return failures ? 1 : 0;
}
