// Complete modular YCbCr streams with explicit subsampled planes.
#include <cstdio>
#include <vector>
#include "jxl/cms.h"
#include "jxl/decode.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_fields.h"
#include "lib/jxl/enc_cache.h"
#include "lib/jxl/enc_modular.h"
#include "lib/jxl/enc_toc.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_quant_weights.h"
#include "lib/jxl/memory_manager_internal.h"
jxl::Status Generate(JxlMemoryManager* memory,unsigned id){
 const unsigned widths[]={13,13,13,13,13,13,257,273,2056,17,519,1};
 const unsigned heights[]={9,9,9,9,9,9,17,33,9,273,17,1};
 const unsigned width=widths[id],height=heights[id];
 jxl::CodecMetadata metadata;JXL_RETURN_IF_ERROR(metadata.size.Set(width,height));metadata.m.SetUintSamples(8);metadata.m.xyb_encoded=false;metadata.m.color_encoding=jxl::ColorEncoding::SRGB();
 jxl::FrameHeader header(&metadata);header.encoding=jxl::FrameEncoding::kModular;header.color_transform=jxl::ColorTransform::kYCbCr;header.loop_filter.gab=false;header.loop_filter.epf_iters=0;
 const uint8_t hs[][3]={{1,1,1},{2,1,1},{2,1,1},{1,1,1},{1,2,2},{2,2,1}},vs[][3]={{1,1,1},{2,1,1},{1,1,1},{2,1,1},{1,2,2},{2,1,2}};
 JXL_RETURN_IF_ERROR(header.chroma_subsampling.Set(hs[id%6],vs[id%6]));const auto dim=header.ToFrameDimensions();
 jxl::CompressParams params;params.SetLossless();params.color_transform=jxl::ColorTransform::kYCbCr;params.gaborish=jxl::Override::kOff;params.epf=0;params.patches=jxl::Override::kOff;params.speed_tier=jxl::SpeedTier::kThunder;JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&params));
 jxl::PassesEncoderState state(memory);state.cparams=params;state.shared.frame_dim=dim;
 JXL_ASSIGN_OR_RETURN(auto encoder,jxl::ModularFrameEncoder::Create(memory,header,params,false));
 JXL_ASSIGN_OR_RETURN(jxl::Image3F image,jxl::Image3F::Create(memory,width,height));
 for(unsigned c=0;c<3;++c)for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x)image.PlaneRow(c,y)[x]=(int((x*13+y*7+c*29)%180)-64)/255.f;
 JXL_RETURN_IF_ERROR(encoder->ComputeEncodingData(header,metadata.m,&image,{},jxl::Rect(0,0,width,height),dim,jxl::Rect(0,0,width,height),&state,*JxlGetDefaultCms(),nullptr,nullptr,true));
 JXL_RETURN_IF_ERROR(encoder->ComputeTree(nullptr));JXL_RETURN_IF_ERROR(encoder->ComputeTokens(nullptr));
 std::vector<std::unique_ptr<jxl::BitWriter>> groups;const size_t count=dim.num_groups==1?1:2+dim.num_dc_groups+dim.num_groups;
 for(size_t i=0;i<count;++i)groups.push_back(std::make_unique<jxl::BitWriter>(memory));auto* group=groups[0].get();
 JXL_RETURN_IF_ERROR(jxl::DequantMatricesEncodeDC(state.shared.matrices,group,jxl::LayerType::Quant,nullptr));
 JXL_RETURN_IF_ERROR(encoder->EncodeGlobalInfo(false,group,nullptr));JXL_RETURN_IF_ERROR(encoder->EncodeStream(group,nullptr,jxl::LayerType::ModularGlobal,jxl::ModularStreamId::Global()));
 for(size_t i=0;i<dim.num_dc_groups;++i)JXL_RETURN_IF_ERROR(encoder->EncodeStream(groups[count==1?0:1+i].get(),nullptr,jxl::LayerType::ModularDcGroup,jxl::ModularStreamId::ModularDC(i)));
 for(size_t i=0;i<dim.num_groups;++i)JXL_RETURN_IF_ERROR(encoder->EncodeStream(groups[count==1?0:2+dim.num_dc_groups+i].get(),nullptr,jxl::LayerType::ModularAcGroup,jxl::ModularStreamId::ModularAC(i,0)));
 for(auto& part:groups)part->ZeroPadToByte();
 jxl::BitWriter writer(memory);JXL_RETURN_IF_ERROR(jxl::WriteCodestreamHeaders(&metadata,&writer,nullptr));writer.ZeroPadToByte();const size_t header_offset=writer.BitsWritten()/8;JXL_RETURN_IF_ERROR(jxl::WriteFrameHeader(header,&writer,nullptr));JXL_RETURN_IF_ERROR(jxl::WriteGroupOffsets(groups,{},&writer,nullptr));
 for(auto& part:groups){auto payload=part->GetSpan();JXL_RETURN_IF_ERROR(writer.WithMaxBits(payload.size()*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(auto byte:payload)writer.Write(8,byte);return true;}));}
 {auto encoded=writer.GetSpan();jxl::BitReader reader(jxl::Bytes(encoded.data()+header_offset,encoded.size()-header_offset));jxl::FrameHeader actual(&metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&reader,&actual));JXL_RETURN_IF_ERROR(reader.Close());if(actual.encoding!=jxl::FrameEncoding::kModular||actual.color_transform!=jxl::ColorTransform::kYCbCr)return false;for(unsigned c=0;c<3;++c)if(actual.chroma_subsampling.HShift(c)!=header.chroma_subsampling.HShift(c)||actual.chroma_subsampling.VShift(c)!=header.chroma_subsampling.VShift(c))return false;}
 auto bytes=writer.GetSpan();auto* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,bytes.data(),bytes.size());JxlDecoderCloseInput(decoder);JxlPixelFormat format={3,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};std::vector<unsigned char> pixels(width*height*3);unsigned frames=0;
 for(;;){auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(decoder,&format,pixels.data(),pixels.size())!=JXL_DEC_SUCCESS)return false;}else if(status==JXL_DEC_FULL_IMAGE)++frames;else return false;}
 JxlDecoderDestroy(decoder);if(frames!=1)return false;printf("pub const bytes_%u=[_]u8{",id);for(auto byte:bytes)printf("%u,",byte);printf("};\npub const pixels_%u=[_]u8{",id);for(auto byte:pixels)printf("%u,",byte);printf("};\n");return true;
}
int main(){JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return 1;printf("// Generated by tests/unit/modular_chroma_oracle.cc with upstream libjxl.\n");for(unsigned id=0;id<12;++id)if(!Generate(&memory,id))return 2;}
