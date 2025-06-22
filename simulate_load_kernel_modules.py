#!/usr/bin/env python3
# encoding: utf-8

import os
import re
import subprocess
import sys
import weakref
from functools import lru_cache
from typing import TypedDict, Set, Dict, Union, Final, Tuple


assert sys.platform == "linux"
for _tool in ("grep", "awk", "modinfo", "modprobe"):
    assert subprocess.getstatusoutput("which '%s'" % _tool)[0] == 0

__AUTHOR__: Final = "Pzqqt"

class Crc:

    @staticmethod
    def crc_to_int(crc: str) -> int:
        if re.match(r'0x[0-9a-fA-F]+', crc):
            return int(crc[2:], 16)
        raise ValueError(crc)

    @staticmethod
    def int_to_crc(num: int) -> str:
        return '0x' + hex(num)[2:].zfill(8)

    def __init__(self, crc: Union[str, int]):
        if isinstance(crc, str):
            self._crc = self.crc_to_int(crc)
        elif isinstance(crc, int):
            if crc < 0 or crc > 0xffffffff:
                raise ValueError("Invalid CRC value: %d" % crc)
            self._crc = crc
        else:
            raise TypeError("Invalid type")

    def to_int(self) -> int:
        return self._crc

    def to_hex(self) -> str:
        return self.int_to_crc(self._crc)

    def __eq__(self, other) -> bool:
        return self._crc == other.to_int()

    __int__ = to_int
    __str__ = to_hex

    def __repr__(self):
        return "Crc(%s)" % self.to_hex()

class KernelModule:

    def __init__(self, module_path: str):
        for char in "\"\\';|<>{}$&*?":
            if char in module_path:
                raise Exception("The path contains illegal characters: %s!" % char)
        realpath = os.path.realpath(module_path)
        if not os.path.isfile(realpath):
            raise Exception("The module file does not exist: %s!" % realpath)
        self.__path = realpath

        # get module name
        rc, output = subprocess.getstatusoutput(
            "modinfo '%s' 2>/dev/null | grep -m1 '^name:' | awk '{print $2}'" % self.__path
        )
        if rc != 0:
            print(output)
            raise RuntimeError("Failed to get module name for '%s'" % self.__path)
        if not output.strip():
            print("Warning: Module %s has no name defined, the file name will be used instead as the module name."
                  % self.__path)
            # The character '-' seems to be disallowed in module names,
            # so it is replaced with an '_'.
            self.__name = os.path.basename(self.__path).split('.', 1)[0].replace('-', '_')
        else:
            self.__name = output.strip()

        # get module symbol versions
        self.__modversions: Dict[str, Crc] = {}
        rc, output = subprocess.getstatusoutput("modprobe '%s' --show-modversions" % self.__path)
        if rc != 0:
            print(output)
            raise RuntimeError("modprobe failed!")
        for line in output.splitlines():
            crc_str, symbol = line.strip().split()
            self.__modversions[symbol] = Crc(crc_str)

        # get module exported symbol versions
        self.__export_modversions: Dict[str, Crc] = {}
        rc, output = subprocess.getstatusoutput("modprobe '%s' --show-exports" % self.__path)
        if rc == 0:
            for line in output.splitlines():
                crc_str, symbol = line.strip().split()
                self.__export_modversions[symbol] = Crc(crc_str)

        self.__cached_depends = None

    @property
    def path(self) -> str:
        return self.__path

    @property
    def name(self) -> str:
        return self.__name

    @property
    def modversions(self) -> Dict[str, Crc]:
        return self.__modversions.copy()

    @property
    def export_modversions(self) -> Dict[str, Crc]:
        return self.__export_modversions.copy()

    @property
    def depends(self) -> Tuple[str, ...]:
        if self.__cached_depends is None:
            rc, output = subprocess.getstatusoutput(
                "modinfo '%s' 2>/dev/null | grep -m1 '^depends:' | awk '{print $2}'" % self.__path
            )
            if rc != 0 or not output.strip():
                self.__cached_depends = tuple()
            else:
                # The character '-' seems to be disallowed in module names,
                # so it is replaced with an '_'.
                self.__cached_depends = tuple([m.replace('-', '_') for m in output.strip().split(',')])
        return self.__cached_depends

    def __repr__(self) -> str:
        return "KernelModule('%s')" % self.name

class VirtualKernelSymbolInfo(TypedDict):
    source: Union[None, KernelModule]
    crc: Crc
    used_by: Set[str]

class VirtualKernel:

    def __init__(self, vmlinux_symvers_file: str, *, ignore_crc_disagree: bool = False, debug: bool = False):
        self.ignore_crc_disagree = ignore_crc_disagree
        self.debug = debug
        self.__symbols: Dict[str, VirtualKernelSymbolInfo] = {}
        # load vmlinux.symvers
        with open(vmlinux_symvers_file, 'r', encoding="utf-8") as f:
            for line in f.readlines():
                line = line.strip()
                symbol_name = line.split()[1]
                symbol_info: VirtualKernelSymbolInfo = {
                    "source": None,
                    "crc": Crc(line.split()[0]),
                    "used_by": set(),
                }
                self.__symbols[symbol_name] = symbol_info
        self.__loaded_modules: Dict[str, KernelModule] = {}
        self._cache_kernel_module = lru_cache(KernelModule)

    @property
    def symbols(self) -> Dict[str, VirtualKernelSymbolInfo]:
        return self.__symbols.copy()

    @property
    def loaded_modules(self):
        return self.__loaded_modules.copy()

    def load_module(self, kernel_module: KernelModule) -> bool:
        if kernel_module.name in self.loaded_modules.keys():
            if self.debug:
                print("Warning: Module %s has already been loaded" % kernel_module.name)
            return True
        if missing_symbols := (kernel_module.modversions.keys() - self.symbols.keys()):
            for symbol in sorted(missing_symbols):
                print("%s: Unknown symbol: %s" % (kernel_module.name, symbol))
            return False
        disagree_crc_symbols = set()
        for sym_name, sym_crc in kernel_module.modversions.items():
            if self.symbols[sym_name]["crc"] != sym_crc:
                disagree_crc_symbols.add(sym_name)
        if disagree_crc_symbols:
            for sym_name in sorted(disagree_crc_symbols):
                print("%s: Disagrees about version of symbol %s, %s (%s) vs %s (%s)" % (
                    kernel_module.name, sym_name,
                    self.symbols[sym_name]["crc"], self.symbols[sym_name]["source"].name,
                    kernel_module.modversions[sym_name], kernel_module.name,
                ))
            if not self.ignore_crc_disagree:
                return False
        if dup_symbols := (kernel_module.export_modversions.keys() & self.symbols.keys()):
            for symbol in sorted(dup_symbols):
                print("%s: Repeated symbol: %s" % (kernel_module.name, symbol))
            return False
        for sym_name, sym_crc in kernel_module.export_modversions.items():
            self.__symbols[sym_name] = {
                "source": weakref.proxy(kernel_module),
                "crc": sym_crc,
                "used_by": set(),
            }
        for sym_name in kernel_module.modversions.keys():
            self.__symbols[sym_name]["used_by"].add(kernel_module.name)
        self.__loaded_modules[kernel_module.name] = kernel_module
        if self.debug:
            print("Loaded kernel module %s" % kernel_module.name)
        return True

    def load_modules(self, modules_load_file: str, real_modules_path: str = "") -> bool:
        # load modules.load
        with open(modules_load_file, 'r', encoding="utf-8") as f:
            modules = [m.strip() for m in f.readlines()]

        modules_dir = os.path.dirname(modules_load_file)

        # load modules.dep
        modules_dep_dic = {}
        if not real_modules_path.endswith("/"):
            real_modules_path += "/"
        skip_char = len(real_modules_path)
        with open(os.path.join(modules_dir, "modules.dep"), 'r', encoding="utf-8") as f:
            for line_no, line in enumerate(f.readlines(), 1):
                line = line.strip()
                line_split = line.split()
                module_abs_path = line_split[0]
                if not module_abs_path.endswith(":"):
                    print(line_split)
                    raise RuntimeError(
                        "Error parsing line %d of %s!" % (line_no, os.path.join(modules_dir, "modules.load"))
                    )
                module_abs_path = module_abs_path[skip_char:-1]
                dep_modules = [m[skip_char:] for m in line_split[1:]]
                modules_dep_dic[module_abs_path] = tuple(dep_modules)

        # Load modules in order according to their dependencies
        remain_modules = set(modules)
        def _load_module(module_abs_path_: str) -> bool:
            for dep_module in reversed(modules_dep_dic[module_abs_path_]):
                if not _load_module(dep_module):
                    return False
            if self.load_module(self._cache_kernel_module(os.path.join(modules_dir, module_abs_path_))):
                if module_abs_path_ in remain_modules:
                    remain_modules.remove(module_abs_path_)
                return True
            return False

        for module in modules:
            if not _load_module(module):
                print("Error: Failed to load %s!" % os.path.join(modules_dir, module))
                print("These kernel modules are still not loaded:")
                for m in sorted(remain_modules):
                    print("-", m)
                return False
        return True

def main(vmlinux_symvers_file: str, *args: str) -> int:
    if not args or len(args) % 2 != 0:
        return 2

    vk = VirtualKernel(vmlinux_symvers_file)

    for i in range(len(args) // 2):
        modules_load_file_, real_modules_path_ = args[i*2], args[i*2+1]
        if not vk.load_modules(modules_load_file_, real_modules_path_):
            return 1

    return 0

if __name__ == "__main__":
    '''
    # Example
    main(
        '/home/pzqqt/working/android_kernel_xiaomi_marble/out/vmlinux.symvers',
        '/mnt/f/OS2.0.6.0.VMRCNXM/vendor_boot_modules/modules.load', "/lib/modules/",
        '/mnt/f/OS2.0.6.0.VMRCNXM/vendor_dlkm_modules/modules.load', "/vendor/lib/modules/",
    )
    '''
    if len(sys.argv) >= 4:
        if (_rc := main(*sys.argv[1:])) != 2:
            sys.exit(_rc)
    print('Usage: %s <vmlinux.symvers file> [<modules.load file> <real modules path>] ...' % sys.argv[0])
    sys.exit(2)
