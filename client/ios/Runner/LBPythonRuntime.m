#import "LBPythonRuntime.h"

#import <Python/Python.h>

static NSString *const LBPythonErrorDomain = @"com.langbai.resolver.python";

@implementation LBPythonRuntime {
    BOOL _initialized;
}

+ (instancetype)sharedRuntime {
    static LBPythonRuntime *runtime = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[LBPythonRuntime alloc] init];
    });
    return runtime;
}

- (BOOL)initializeRuntime:(NSError **)error {
    @synchronized(self) {
        if (_initialized) {
            return YES;
        }

        NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
        NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];
        NSString *appPath = [resourcePath stringByAppendingPathComponent:@"app"];
        NSString *packagesPath = [resourcePath stringByAppendingPathComponent:@"app_packages"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:pythonHome]) {
            [self setError:error message:@"IPA 未包含 iOS Python 运行时，请重新安装完整版本"];
            return NO;
        }

        PyStatus status;
        PyPreConfig preconfig;
        PyConfig config;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        PyConfig_InitIsolatedConfig(&config);
        preconfig.utf8_mode = 1;
        config.use_system_logger = 1;
        config.buffered_stdio = 0;
        config.write_bytecode = 0;
        config.install_signal_handlers = 1;

        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            [self setError:error message:[self statusMessage:status fallback:@"Python 预初始化失败"]];
            PyConfig_Clear(&config);
            return NO;
        }

        wchar_t *home = Py_DecodeLocale([pythonHome UTF8String], NULL);
        status = PyConfig_SetString(&config, &config.home, home);
        PyMem_RawFree(home);
        if (PyStatus_Exception(status)) {
            [self setError:error message:[self statusMessage:status fallback:@"无法设置 Python 目录"]];
            PyConfig_Clear(&config);
            return NO;
        }

        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            [self setError:error message:[self statusMessage:status fallback:@"无法读取 Python 配置"]];
            PyConfig_Clear(&config);
            return NO;
        }

        status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            [self setError:error message:[self statusMessage:status fallback:@"Python 初始化失败"]];
            return NO;
        }

        PyObject *siteModule = PyImport_ImportModule("site");
        PyObject *addSiteDir = siteModule ? PyObject_GetAttrString(siteModule, "addsitedir") : NULL;
        PyObject *packages = PyUnicode_FromString([packagesPath UTF8String]);
        PyObject *siteResult =
            (addSiteDir && PyCallable_Check(addSiteDir) && packages)
                ? PyObject_CallFunctionObjArgs(addSiteDir, packages, NULL)
                : NULL;
        Py_XDECREF(siteResult);
        Py_XDECREF(packages);
        Py_XDECREF(addSiteDir);
        Py_XDECREF(siteModule);
        if (PyErr_Occurred()) {
            NSString *message = [self consumePythonError:@"无法加载 iOS 解析器依赖"];
            [self setError:error message:message];
            return NO;
        }

        PyObject *sysPath = PySys_GetObject("path");
        PyObject *app = PyUnicode_FromString([appPath UTF8String]);
        if (!sysPath || !app || PyList_Insert(sysPath, 0, app) != 0) {
            Py_XDECREF(app);
            NSString *message = [self consumePythonError:@"无法加载 iOS 解析器代码"];
            [self setError:error message:message];
            return NO;
        }
        Py_DECREF(app);

        PyObject *module = PyImport_ImportModule("resolver_bridge");
        if (!module) {
            NSString *message = [self consumePythonError:@"无法导入 iOS 本地解析器"];
            [self setError:error message:message];
            return NO;
        }
        Py_DECREF(module);

        _initialized = YES;
        PyEval_SaveThread();
        return YES;
    }
}

- (NSString *)callFunction:(NSString *)functionName
               jsonArgument:(NSString *)jsonArgument
                      error:(NSError **)error {
    if (![self initializeRuntime:error]) {
        return nil;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    NSString *output = nil;
    PyObject *module = PyImport_ImportModule("resolver_bridge");
    PyObject *function = module ? PyObject_GetAttrString(module, [functionName UTF8String]) : NULL;
    PyObject *argument = PyUnicode_FromString([jsonArgument UTF8String]);
    PyObject *result =
        (function && PyCallable_Check(function) && argument)
            ? PyObject_CallFunctionObjArgs(function, argument, NULL)
            : NULL;

    if (result && PyUnicode_Check(result)) {
        const char *utf8 = PyUnicode_AsUTF8(result);
        if (utf8) {
            output = [NSString stringWithUTF8String:utf8];
        }
    }
    if (!output) {
        NSString *message = [self consumePythonError:@"iOS 本地解析执行失败"];
        [self setError:error message:message];
    }

    Py_XDECREF(result);
    Py_XDECREF(argument);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyGILState_Release(gil);
    return output;
}

- (NSString *)consumePythonError:(NSString *)fallback {
    if (!PyErr_Occurred()) {
        return fallback;
    }
    PyObject *type = NULL;
    PyObject *value = NULL;
    PyObject *traceback = NULL;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);
    PyObject *description = value ? PyObject_Str(value) : NULL;
    const char *utf8 = description ? PyUnicode_AsUTF8(description) : NULL;
    NSString *message = utf8 ? [NSString stringWithUTF8String:utf8] : fallback;
    Py_XDECREF(description);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    return message.length > 500 ? [message substringToIndex:500] : message;
}

- (NSString *)statusMessage:(PyStatus)status fallback:(NSString *)fallback {
    return status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : fallback;
}

- (void)setError:(NSError **)error message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:LBPythonErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
}

@end
