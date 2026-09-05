#include <array>
#include <cstdio>
#include "lib/jxl/frame_header.h"
#include "lib/jxl/dec_bit_reader.h"
int main(){for(unsigned shift=0;shift<4;++shift){jxl::CodecMetadata metadata;metadata.m.xyb_encoded=true;metadata.m.extra_channel_info.resize(1);metadata.m.extra_channel_info[0].dim_shift=shift;jxl::FrameHeader header(&metadata);const std::array<unsigned char,1> data={1};jxl::BitReader reader(data);if(!jxl::ReadFrameHeader(&reader,&header))return 1;printf("%u %u %u\n",shift,header.upsampling,header.extra_channel_upsampling[0]);if(!reader.Close())return 2;}}
