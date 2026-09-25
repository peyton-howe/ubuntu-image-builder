/* SPDX-License-Identifier: (GPL-2.0-or-later OR MIT) */
#ifndef _RKISP2_V4L2_COMPAT_H
#define _RKISP2_V4L2_COMPAT_H

#include <linux/device.h>
#include <linux/err.h>
#include <linux/string.h>
#include <media/v4l2-isp.h>

/*
 * rkisp2 v3 was written against a later V4L2 ISP stats helper API.
 * linux-stable 7.2 only has the params-side names.
 */

#ifndef v4l2_isp_buffer
#define v4l2_isp_buffer v4l2_isp_params_buffer
#endif

#ifndef v4l2_isp_buffer_size
#define v4l2_isp_buffer_size v4l2_isp_params_buffer_size
#endif

#ifndef V4L2_ISP_VERSION_V1
#define V4L2_ISP_VERSION_V1 V4L2_ISP_PARAMS_VERSION_V1
#endif

#ifndef v4l2_isp_stats_block_type_info
#define v4l2_isp_stats_block_type_info v4l2_isp_params_block_type_info
#endif

#ifndef v4l2_isp_stats_init_buffer
#define v4l2_isp_stats_init_buffer rkisp2_v4l2_stats_init_buffer
static inline void rkisp2_v4l2_stats_init_buffer(struct v4l2_isp_params_buffer *buf,
						 u32 version)
{
	buf->version = version;
	buf->data_size = 0;
}
#endif

#ifndef v4l2_isp_stats_init_block
#define v4l2_isp_stats_init_block rkisp2_v4l2_stats_init_block
static inline void *
rkisp2_v4l2_stats_init_block(struct device *dev, struct v4l2_isp_params_buffer *buf,
			     const struct v4l2_isp_params_block_type_info *info,
			     size_t ntypes, unsigned int type, size_t max_size)
{
	struct v4l2_isp_params_block_header *hdr;
	size_t size;

	if (type >= ntypes || !info[type].size)
		return ERR_PTR(-EINVAL);

	size = info[type].size;
	if (buf->data_size + size > max_size) {
		dev_err(dev, "ISP stats buffer overflow (type %u)\n", type);
		return ERR_PTR(-ENOSPC);
	}

	hdr = (struct v4l2_isp_params_block_header *)(buf->data + buf->data_size);
	memset(hdr, 0, size);
	hdr->type = type;
	hdr->size = size;
	buf->data_size += size;

	return hdr;
}
#endif

#endif /* _RKISP2_V4L2_COMPAT_H */
