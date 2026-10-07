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
typedef int (WINAPI *dpi_fn)(void *, float *);
struct rectf { float x,y,w,h; };
typedef int (WINAPI *measure_fn)(void *, const WCHAR *, int, void *, const struct rectf *, void *, struct rectf *, int *, int *);
typedef int (WINAPI *delete_fn)(void *);
typedef void (WINAPI *shutdown_fn)(ULONG_PTR);

#define GET(var, name, type) type var = (type)GetProcAddress(module, name); if (!var) { printf("Missing %s\n", name); return 2; }
#define OK(call) do { int status = (call); if (status) { printf("%s => %d\n", #call, status); return 3; } } while (0)

int main(int argc, char **argv)
{
    HMODULE module;
    ULONG_PTR token;
    struct startup_input input = {1};
    void *family, *font, *image, *graphics;
    float height, expected;
    int unit, dpi, page, cases=0, failures=0;
    static const float expected_bounds[3][2][3] = {{{16.083984f,24.125977f,32.167969f},{21.445312f,32.167969f,42.890625f}},{{14.90625f,22.359375f,29.8125f},{19.875f,29.8125f,39.75f}},{{15.984375f,23.976562f,31.96875f},{21.3125f,31.96875f,42.625f}}};
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
    GET(measure,"GdipMeasureString",measure_fn);

    if (late_aware) printf("late SetProcessDPIAware=%d\n", SetProcessDPIAware());
    for (int fam=0;fam<3;fam++) {
    OK(create_family(fam==0?L"Verdana":fam==1?L"Arial":L"Tahoma",NULL,&family));
    for (int style=0;style<2;style++) for (unit=0;unit<=1;unit++) {
        OK(create_font(family,unit ? 12.0f : 9.0f,style,3,&font));
        for(dpi=96;dpi<=192;dpi+=48) {
            struct rectf layout={0,0,1000,1000}, bounds;
            int fitted, lines;
            OK(create_bitmap(1200,1200,0,0x26200a,NULL,&image));
            OK(resolution(image,dpi,dpi));
            OK(create_graphics(image,&graphics));
            OK(measure(graphics,L"Search Result Gy",-1,font,&layout,NULL,&bounds,&fitted,&lines));
            OK(get_height(font,graphics,&height));
            OK(dpi_height(font,dpi,&expected));
            ++cases;
            // Values observed with Microsoft GDI+ and the Windows core fonts.
            // Allow subpixel GDI rounding, but reject clipped line/overhang heights.
            if (fabsf(bounds.h-expected_bounds[fam][unit][(dpi-96)/48]) > 0.11f || lines!=1 || fitted!=16) {
                ++failures;printf("FAIL family=%d style=%d point=%d dpi=%d height=%.6f expected=%.6f lines=%d fitted=%d\n",fam,style,unit?12:9,dpi,bounds.h,expected_bounds[fam][unit][(dpi-96)/48],lines,fitted);
            }
            OK(delete_graphics(graphics));OK(delete_image(image));
        }
        OK(delete_font(font));
    }
    // Pixel-font bounds remain in pixels even with a different graphics page unit.
    // Native measurements equal a 9-point font at 96 DPI (12 pixels).
    for (int style=0;style<2;style++) {
        static const int pages[] = {2,3,6};
        OK(create_font(family,12.0f,style,2,&font));
        for (dpi=96;dpi<=192;dpi+=48) for (page=0;page<3;page++) {
            struct rectf layout={0,0,1000,1000}, bounds;
            int fitted, lines;
            OK(create_bitmap(1200,1200,0,0x26200a,NULL,&image));
            OK(resolution(image,dpi,dpi));OK(create_graphics(image,&graphics));
            OK(page_unit(graphics,pages[page]));
            OK(measure(graphics,L"Search Result Gy",-1,font,&layout,NULL,&bounds,&fitted,&lines));
            ++cases;
            if (fabsf(bounds.h-expected_bounds[fam][0][0]) > 0.11f || lines!=1 || fitted!=16) {
                ++failures;printf("FAIL pixel family=%d style=%d page=%d dpi=%d height=%.6f expected=%.6f\n",fam,style,pages[page],dpi,bounds.h,expected_bounds[fam][0][0]);
            }
            OK(delete_graphics(graphics));OK(delete_image(image));
        }
        OK(delete_font(font));
    }
    OK(delete_family(family));
    }
    shutdown(token);
    printf("%d/%d text bounds cases passed\n",cases-failures,cases);
    return failures?1:0;
}
