// SPDX-License-Identifier: GPL-2.0
/*
 * IIO DMA consumer for the custom FPGA control stream.
 *
 * The actual DMA engine is the ADI AXI-DMAC at 0x7c400000.
 *
 * One IIO scan contains:
 *
 *   AVG0 : signed 32 bit
 *   AVG1 : signed 32 bit
 *   AVG2 : signed 32 bit
 *   AVG3   : signed 32 bit
 *   PHASE0 : signed 32 bit, wrapped CORDIC phase (BAM)
 *   PHASE1 : signed 32 bit, wrapped CORDIC phase (BAM)
 *   AO0    : unsigned 16 bit
 *   AO1    : unsigned 16 bit
 *   AO2    : unsigned 16 bit
 *   AO3    : unsigned 16 bit
 *
 * Total scan size: 32 bytes.
 *
 * The FPGA is expected to serialize one scan as eight 32-bit DMA words:
 *
 *   word0 = AVG0
 *   word1 = AVG1
 *   word2 = AVG2
 *   word3 = AVG3
 *   word4 = PHASE0
 *   word5 = PHASE1
 *   word6 = { AO1, AO0 }
 *   word7 = { AO3, AO2 }
 *
 * This driver does not control the FPGA datapath, PID, or DAC.
 * It only exposes the DMA stream through the Linux IIO buffer API.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>

#include <linux/iio/iio.h>
#include <linux/iio/buffer.h>
#include <linux/iio/buffer-dmaengine.h>






static const struct iio_chan_spec control_channels[] = {
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 0,
		.extend_name = "avg0",
		.scan_index = 0,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 1,
		.extend_name = "avg1",
		.scan_index = 1,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 2,
		.extend_name = "avg2",
		.scan_index = 2,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 3,
		.extend_name = "avg3",
		.scan_index = 3,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 4,
		.extend_name = "phase0",
		.scan_index = 4,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 5,
		.extend_name = "phase1",
		.scan_index = 5,
		.scan_type = {
			.sign = 's',
			.realbits = 32,
			.storagebits = 32,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 6,
		.extend_name = "ao0",
		.scan_index = 6,
		.scan_type = {
			.sign = 'u',
			.realbits = 16,
			.storagebits = 16,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 7,
		.extend_name = "ao1",
		.scan_index = 7,
		.scan_type = {
			.sign = 'u',
			.realbits = 16,
			.storagebits = 16,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 8,
		.extend_name = "ao2",
		.scan_index = 8,
		.scan_type = {
			.sign = 'u',
			.realbits = 16,
			.storagebits = 16,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
	{
		.type = IIO_VOLTAGE,
		.indexed = 1,
		.channel = 9,
		.extend_name = "ao3",
		.scan_index = 9,
		.scan_type = {
			.sign = 'u',
			.realbits = 16,
			.storagebits = 16,
			.shift = 0,
			.endianness = IIO_LE,
		},
	},
        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 10,
                .extend_name = "ao4",
                .scan_index = 10,
                .scan_type = {
                        .sign = 'u',
                        .realbits = 20,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 11,
                .extend_name = "ao5",
                .scan_index = 11,
                .scan_type = {
                        .sign = 'u',
                        .realbits = 20,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 12,
                .extend_name = "pid0",
                .scan_index = 12,
                .scan_type = {
                        .sign = 's',
                        .realbits = 32,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 13,
                .extend_name = "pid1",
                .scan_index = 13,
                .scan_type = {
                        .sign = 's',
                        .realbits = 32,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 14,
                .extend_name = "pid2",
                .scan_index = 14,
                .scan_type = {
                        .sign = 's',
                        .realbits = 32,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

        {
                .type = IIO_VOLTAGE,
                .indexed = 1,
                .channel = 15,
                .extend_name = "pid3",
                .scan_index = 15,
                .scan_type = {
                        .sign = 's',
                        .realbits = 32,
                        .storagebits = 32,
                        .shift = 0,
                        .endianness = IIO_LE,
                },
        },

};


/*
 * No direct register attributes are required for the first test.
 *
 * Data is obtained only through the IIO DMA buffer.
 */
static const struct iio_info control_iio_info = {
};


static int control_iio_probe(struct platform_device *pdev)
{
	struct iio_dev *indio_dev;
	int ret;

	dev_info(&pdev->dev, "probing control IIO DMA stream\n");

	/*
	 * No private driver state is needed yet, therefore private size = 0.
	 */
	indio_dev = devm_iio_device_alloc(&pdev->dev, 0);
	if (!indio_dev)
		return -ENOMEM;

	indio_dev->name = "control_stream";
	indio_dev->dev.parent = &pdev->dev;

	indio_dev->info = &control_iio_info;
	indio_dev->modes = INDIO_DIRECT_MODE;

	indio_dev->channels = control_channels;
	indio_dev->num_channels = ARRAY_SIZE(control_channels);

	/*
	 * Request the DMA channel named "rx".
	 *
	 * Device Tree must contain:
	 *
	 *   dmas = <&ao_dma 0>;
	 *   dma-names = "rx";
	 *
	 * The IIO DMAEngine helper handles DMA buffer allocation,
	 * DMA submission and integration with the IIO buffer API.
	 */
	ret = devm_iio_dmaengine_buffer_setup(
		&pdev->dev,
		indio_dev,
		"rx",
		IIO_BUFFER_DIRECTION_IN
	);
	if (ret) {
		dev_err(&pdev->dev,
			"failed to setup IIO DMA buffer: %d\n",
			ret);
		return ret;
	}

	/*
	 * Register the IIO device.
	 *
	 * When successful, a new:
	 *
	 *   /sys/bus/iio/devices/iio:deviceX
	 *
	 * should appear.
	 */
	ret = devm_iio_device_register(&pdev->dev, indio_dev);
	if (ret) {
		dev_err(&pdev->dev,
			"failed to register IIO device: %d\n",
			ret);
		return ret;
	}

	dev_info(&pdev->dev, "control IIO DMA stream registered\n");

	return 0;
}


static const struct of_device_id control_iio_of_match[] = {
	{
		.compatible = "jpark,control-iio-stream",
	},
	{ }
};
MODULE_DEVICE_TABLE(of, control_iio_of_match);


static struct platform_driver control_iio_driver = {
	.probe = control_iio_probe,
	.driver = {
		.name = "control-iio-stream",
		.of_match_table = control_iio_of_match,
	},
};

module_platform_driver(control_iio_driver);


MODULE_AUTHOR("June Gyu Park");
MODULE_DESCRIPTION("IIO DMA consumer for FPGA control stream");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS(IIO_DMAENGINE_BUFFER);