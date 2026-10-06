/* Exercise the AD17 startup properties and null-name lookup regression. */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <initguid.h>
#include "msado15_backcompat.h"
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { printf("FAIL line %d\n", __LINE__); return 1; } } while (0)

int main(void)
{
    CLSID clsid;
    _Command *command;
    _Parameter *parameter, *found;
    Parameters *parameters;
    VARIANT value, index;
    VARIANT_BOOL prepared;
    LONG timeout;
    unsigned char precision;
    BSTR name = SysAllocString(L"part");

    CHECK(SUCCEEDED(CoInitialize(NULL)));
    CHECK(SUCCEEDED(CLSIDFromProgID(L"ADODB.Command", &clsid)));
    CHECK(SUCCEEDED(CoCreateInstance(&clsid, NULL, CLSCTX_INPROC_SERVER, &IID__Command, (void **)&command)));
    CHECK(_Command_get_CommandTimeout(command, &timeout) == S_OK && timeout == 30);
    CHECK(_Command_put_CommandTimeout(command, 17) == S_OK);
    CHECK(_Command_get_CommandTimeout(command, &timeout) == S_OK && timeout == 17);
    CHECK(_Command_put_Prepared(command, VARIANT_TRUE) == S_OK);
    CHECK(_Command_get_Prepared(command, &prepared) == S_OK && prepared == VARIANT_TRUE);
    VariantInit(&value);
    CHECK(_Command_CreateParameter(command, name, adInteger, adParamInput, 4, value, &parameter) == S_OK);
    CHECK(_Parameter_put_Precision(parameter, 8) == S_OK);
    CHECK(_Parameter_get_Precision(parameter, &precision) == S_OK && precision == 8);
    CHECK(_Command_get_Parameters(command, &parameters) == S_OK);
    CHECK(Parameters_Append(parameters, (IDispatch *)parameter) == S_OK);
    VariantInit(&index);
    V_VT(&index) = VT_BSTR;
    V_BSTR(&index) = name;
    CHECK(Parameters_get_Item(parameters, index, &found) == S_OK);
    _Parameter_Release(found);
    V_BSTR(&index) = NULL;
    found = (_Parameter *)1;
    CHECK(FAILED(Parameters_get_Item(parameters, index, &found)) && found == NULL);
    V_VT(&index) = VT_I4;
    V_I4(&index) = 0;
    CHECK(Parameters_get_Item(parameters, index, &found) == S_OK);
    _Parameter_Release(found);
    Parameters_Release(parameters);
    _Parameter_Release(parameter);
    _Command_Release(command);
    SysFreeString(name);
    CoUninitialize();
    puts("PASS ADO properties and parameter lookup by name, null name and index");
    return 0;
}
