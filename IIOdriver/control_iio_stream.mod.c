#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/export-internal.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

BUILD_SALT;
BUILD_LTO_INFO;

MODULE_INFO(vermagic, VERMAGIC_STRING);
MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

#ifdef CONFIG_RETPOLINE
MODULE_INFO(retpoline, "Y");
#endif


static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0x79a01c08, "__platform_driver_register" },
	{ 0xefd6cf06, "__aeabi_unwind_cpp_pr0" },
	{ 0xd3b5cb4d, "_dev_info" },
	{ 0xd59b0cd2, "devm_iio_device_alloc" },
	{ 0xb6bf3f37, "devm_iio_dmaengine_buffer_setup" },
	{ 0xfac24478, "_dev_err" },
	{ 0xd01f4945, "__devm_iio_device_register" },
	{ 0xb0a8fa3d, "platform_driver_unregister" },
	{ 0xd0b4f4f6, "module_layout" },
};

MODULE_INFO(depends, "");

MODULE_ALIAS("of:N*T*Cjpark,control-iio-stream");
MODULE_ALIAS("of:N*T*Cjpark,control-iio-streamC*");
