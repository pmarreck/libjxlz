// Progressive DC frames and final display pixels from upstream libjxl.
#include <cstdio>
#include <vector>
#include "jxl/encode.h"
#include "jxl/decode.h"
#include "jxl/color_encoding.h"
#include "lib/jxl/fields.h"
#include "lib/jxl/frame_header.h"
#include "lib/jxl/toc.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_toc.h"
#include "lib/jxl/enc_fields.h"
#include "lib/jxl/enc_aux_out.h"
// A 1x1 DC pyramid keeps every level 1x1. Reuse independently encoded
// sections, rewriting only the frame levels that the public encoder limits.
bool ExtendLevels(std::vector<unsigned char>* bytes,unsigned levels){
 JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return false;
 jxl::CodecMetadata metadata;jxl::BitReader bits(jxl::Bytes(bytes->data()+2,bytes->size()-2));
 if(!jxl::ReadSizeHeader(&bits,&metadata.size)||!jxl::ReadImageMetadata(&bits,&metadata.m))return false;
 metadata.transform_data.nonserialized_xyb_encoded=metadata.m.xyb_encoded;
 if(!jxl::Bundle::Read(&bits,&metadata.transform_data)||!bits.JumpToByteBoundary())return false;
 size_t offset=2+bits.TotalBitsConsumed()/8;if(!bits.Close())return false;
 jxl::BitWriter writer(&memory);
 if(!writer.WithMaxBits(offset*8,jxl::LayerType::Header,nullptr,[&]{for(size_t i=0;i<offset;++i)writer.Write(8,(*bytes)[i]);return true;}))return false;
 for(unsigned frame=0;frame<3;++frame){
  jxl::BitReader reader(jxl::Bytes(bytes->data()+offset,bytes->size()-offset));jxl::FrameHeader header(&metadata);
  if(!jxl::ReadFrameHeader(&reader,&header))return false;
  std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;
  if(!jxl::ReadToc(&memory,1,&reader,&sizes,&permutation)||!reader.JumpToByteBoundary())return false;
  offset+=reader.TotalBitsConsumed()/8;if(!reader.Close())return false;
  std::vector<std::unique_ptr<jxl::BitWriter>> groups;groups.push_back(std::make_unique<jxl::BitWriter>(&memory));
  if(!groups[0]->WithMaxBits(sizes[0]*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=0;i<sizes[0];++i)groups[0]->Write(8,(*bytes)[offset+i]);return true;}))return false;
  offset+=sizes[0];
  const unsigned repetitions=frame==1?levels-1:1;
  for(unsigned copy=0;copy<repetitions;++copy){
   header.dc_level=frame==0?levels:frame==1?levels-1-copy:0;
   if(!jxl::WriteFrameHeader(header,&writer,nullptr)||!jxl::WriteGroupOffsets(groups,{},&writer,nullptr))return false;
   auto section=groups[0]->GetSpan();if(!writer.WithMaxBits(section.size()*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(auto byte:section)writer.Write(8,byte);return true;}))return false;
  }
 }
 if(offset!=bytes->size())return false;
 auto result=writer.GetSpan();bytes->assign(result.begin(),result.end());return true;
}
bool CheckFrames(const std::vector<unsigned char>& bytes,unsigned id,unsigned levels){
 JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return false;
 jxl::CodecMetadata metadata;jxl::BitReader bits(jxl::Bytes(bytes.data()+2,bytes.size()-2));
 if(!jxl::ReadSizeHeader(&bits,&metadata.size)||!jxl::ReadImageMetadata(&bits,&metadata.m))return false;
 metadata.transform_data.nonserialized_xyb_encoded=metadata.m.xyb_encoded;
 if(!jxl::Bundle::Read(&bits,&metadata.transform_data)||!bits.JumpToByteBoundary())return false;
 size_t offset=2+bits.TotalBitsConsumed()/8;if(!bits.Close())return false;unsigned frames=0;
 printf("pub const offsets_%u=[_]usize{",id);
 while(offset<bytes.size()){
  printf("%zu,",offset);jxl::BitReader reader(jxl::Bytes(bytes.data()+offset,bytes.size()-offset));jxl::FrameHeader header(&metadata);
  if(!jxl::ReadFrameHeader(&reader,&header))return false;
  const auto dim=header.ToFrameDimensions();std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;
  if(!jxl::ReadToc(&memory,jxl::NumTocEntries(dim.num_groups,dim.num_dc_groups,header.passes.num_passes),&reader,&sizes,&permutation)||!reader.JumpToByteBoundary())return false;
  if(header.dc_level!=levels-frames||header.frame_type!=(frames<levels?jxl::FrameType::kDCFrame:jxl::FrameType::kRegularFrame)||bool(header.flags&jxl::FrameHeader::kUseDcFrame)!=(frames!=0)){fprintf(stderr,"unexpected DC header id=%u frame=%u\n",id,frames);return false;}
  offset+=reader.TotalBitsConsumed()/8;for(auto size:sizes)offset+=size;if(!reader.Close())return false;++frames;
 }
 printf("};\n");return frames==levels+1&&offset==bytes.size();
}
bool MissingReference(const std::vector<unsigned char>& bytes,unsigned level){
 JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return false;
 jxl::CodecMetadata metadata;jxl::BitReader bits(jxl::Bytes(bytes.data()+2,bytes.size()-2));
 if(!jxl::ReadSizeHeader(&bits,&metadata.size)||!jxl::ReadImageMetadata(&bits,&metadata.m))return false;
 metadata.transform_data.nonserialized_xyb_encoded=metadata.m.xyb_encoded;
 if(!jxl::Bundle::Read(&bits,&metadata.transform_data)||!bits.JumpToByteBoundary())return false;
 const size_t start=2+bits.TotalBitsConsumed()/8;if(!bits.Close())return false;
 jxl::BitReader reader(jxl::Bytes(bytes.data()+start,bytes.size()-start));jxl::FrameHeader header(&metadata);
 if(!jxl::ReadFrameHeader(&reader,&header)||header.encoding!=jxl::FrameEncoding::kModular)return false;
 std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;
 if(!jxl::ReadToc(&memory,1,&reader,&sizes,&permutation)||!reader.JumpToByteBoundary())return false;
 const size_t payload=start+reader.TotalBitsConsumed()/8;if(!reader.Close())return false;
 jxl::BitWriter writer(&memory);if(!writer.WithMaxBits(start*8,jxl::LayerType::Header,nullptr,[&]{for(size_t i=0;i<start;++i)writer.Write(8,bytes[i]);return true;}))return false;
 std::vector<std::unique_ptr<jxl::BitWriter>> groups;groups.push_back(std::make_unique<jxl::BitWriter>(&memory));
 if(!groups[0]->WithMaxBits(sizes[0]*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=0;i<sizes[0];++i)groups[0]->Write(8,bytes[payload+i]);return true;}))return false;
 header.dc_level=level;header.flags|=jxl::FrameHeader::kUseDcFrame;
 if(!jxl::WriteFrameHeader(header,&writer,nullptr)||!jxl::WriteGroupOffsets(groups,{},&writer,nullptr))return false;
 if(!writer.WithMaxBits((bytes.size()-payload)*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=payload;i<bytes.size();++i)writer.Write(8,bytes[i]);return true;}))return false;
 auto result=writer.GetSpan();auto* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,result.data(),result.size());JxlDecoderCloseInput(decoder);
 const auto status=JxlDecoderProcessInput(decoder);JxlDecoderDestroy(decoder);if(status!=JXL_DEC_ERROR)return false;
 printf("pub const missing_%u=[_]u8{",level-1);for(auto byte:result)printf("%u,",byte);printf("};\n");return true;
}
int main(){
 printf("// Generated by tests/unit/progressive_dc_oracle.cc with upstream libjxl.\n");
 for(unsigned id=0;id<10;++id){
  const unsigned widths[]={13,13,65,65,272,272,2056,2056,1,1},heights[]={9,9,33,33,19,19,8,8,1,1};
  const unsigned width=widths[id],height=heights[id],channels=id<4||id>=8?3:4,levels=id>=8?id-5:1+id%2;
  std::vector<unsigned char> pixels(width*height*channels);for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x)for(unsigned c=0;c<channels;++c)pixels[(y*width+x)*channels+c]=(x*(13+c*3)+y*(7+c*5)+c*29)%256;
  auto* encoder=JxlEncoderCreate(nullptr);JxlBasicInfo info;JxlEncoderInitBasicInfo(&info);info.xsize=width;info.ysize=height;info.bits_per_sample=8;info.num_color_channels=3;info.uses_original_profile=JXL_FALSE;if(channels==4){info.num_extra_channels=1;info.alpha_bits=8;}
  if(JxlEncoderSetBasicInfo(encoder,&info)!=JXL_ENC_SUCCESS)return 1;
  JxlColorEncoding color;JxlColorEncodingSetToSRGB(&color,JXL_FALSE);if(JxlEncoderSetColorEncoding(encoder,&color)!=JXL_ENC_SUCCESS)return 2;
  auto* settings=JxlEncoderFrameSettingsCreate(encoder,nullptr);if(JxlEncoderSetFrameDistance(settings,1.f)!=JXL_ENC_SUCCESS)return 3;
  for(auto option:{JXL_ENC_FRAME_SETTING_EPF,JXL_ENC_FRAME_SETTING_GABORISH,JXL_ENC_FRAME_SETTING_PATCHES,JXL_ENC_FRAME_SETTING_NOISE,JXL_ENC_FRAME_SETTING_MODULAR})if(JxlEncoderFrameSettingsSetOption(settings,option,0)!=JXL_ENC_SUCCESS)return 4;
  if(JxlEncoderFrameSettingsSetOption(settings,JXL_ENC_FRAME_SETTING_EFFORT,5)!=JXL_ENC_SUCCESS||JxlEncoderFrameSettingsSetOption(settings,JXL_ENC_FRAME_SETTING_PROGRESSIVE_DC,std::min(levels,2u))!=JXL_ENC_SUCCESS)return 5;
  if(id>=4&&id<8&&JxlEncoderFrameSettingsSetOption(settings,JXL_ENC_FRAME_SETTING_PROGRESSIVE_AC,1)!=JXL_ENC_SUCCESS)return 6;
  JxlPixelFormat format={channels,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};if(JxlEncoderAddImageFrame(settings,&format,pixels.data(),pixels.size())!=JXL_ENC_SUCCESS)return 7;JxlEncoderCloseInput(encoder);
  std::vector<unsigned char> compressed(1<<20);auto* next=compressed.data();size_t avail=compressed.size();if(JxlEncoderProcessOutput(encoder,&next,&avail)!=JXL_ENC_SUCCESS)return 8;compressed.resize(compressed.size()-avail);JxlEncoderDestroy(encoder);
  if(id>=8&&!ExtendLevels(&compressed,levels))return 13;
  if(id==8)for(unsigned level=1;level<=4;++level)if(!MissingReference(compressed,level))return 14;
  if(!CheckFrames(compressed,id,levels))return 9;
  auto* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,compressed.data(),compressed.size());JxlDecoderCloseInput(decoder);std::vector<unsigned char> output(pixels.size());unsigned displayed=0;
  for(;;){auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(decoder,&format,output.data(),output.size())!=JXL_DEC_SUCCESS)return 10;}else if(status==JXL_DEC_FULL_IMAGE)++displayed;else return 11;}
  JxlDecoderDestroy(decoder);if(displayed!=1)return 12;
  printf("pub const bytes_%u=[_]u8{",id);for(auto byte:compressed)printf("%u,",byte);printf("};\npub const pixels_%u=[_]u8{",id);for(auto byte:output)printf("%u,",byte);printf("};\n");
 }
}
