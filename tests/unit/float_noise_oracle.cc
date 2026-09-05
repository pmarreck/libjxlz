// Reference storage, cropped layers and all frame blend modes via libjxl.
#include <cstdio>
#include <cstring>
#include <vector>
#include "jxl/cms.h"
#include "jxl/decode.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_fields.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/enc_toc.h"
#include "lib/jxl/toc.h"
#include "lib/jxl/enc_aux_out.h"
jxl::Status Inject(JxlMemoryManager* memory,jxl::CodecMetadata* metadata,const jxl::BitWriter& encoded,jxl::BitWriter* writer,unsigned id){
 jxl::BitReader reader(encoded.GetSpan());jxl::FrameHeader header(metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&reader,&header));
 if(header.flags&(jxl::FrameHeader::kPatches|jxl::FrameHeader::kSplines|jxl::FrameHeader::kNoise))return false;
 const auto dim=header.ToFrameDimensions();std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;
 JXL_RETURN_IF_ERROR(jxl::ReadToc(memory,jxl::NumTocEntries(dim.num_groups,dim.num_dc_groups,header.passes.num_passes),&reader,&sizes,&permutation));JXL_RETURN_IF_ERROR(reader.JumpToByteBoundary());
 size_t offset=reader.TotalBitsConsumed()/8;JXL_RETURN_IF_ERROR(reader.Close());if(!permutation.empty())return false;
 std::vector<std::unique_ptr<jxl::BitWriter>> groups;auto bytes=encoded.GetSpan();
 for(size_t section=0;section<sizes.size();++section){
  groups.push_back(std::make_unique<jxl::BitWriter>(memory));
  if(section==0)JXL_RETURN_IF_ERROR(groups.back()->WithMaxBits(80,jxl::LayerType::Noise,nullptr,[&]{for(unsigned p=0;p<8;++p)groups.back()->Write(10,id==0?0:(id*31+p*71)%1024);return true;}));
  JXL_RETURN_IF_ERROR(groups.back()->WithMaxBits(sizes[section]*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=0;i<sizes[section];++i)groups.back()->Write(8,bytes[offset+i]);return true;}));offset+=sizes[section];
 }
 if(offset!=bytes.size())return false;header.flags|=jxl::FrameHeader::kNoise;
 JXL_RETURN_IF_ERROR(jxl::WriteFrameHeader(header,writer,nullptr));JXL_RETURN_IF_ERROR(jxl::WriteGroupOffsets(groups,{},writer,nullptr));
 for(auto& group:groups){auto section=group->GetSpan();JXL_RETURN_IF_ERROR(writer->WithMaxBits(section.size()*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(auto byte:section)writer->Write(8,byte);return true;}));}return true;
}
jxl::Status Generate(JxlMemoryManager* memory,unsigned id){
 const unsigned width=13,height=9,extras=(id%10)/5,channels=3+extras;
 jxl::CodecMetadata metadata;JXL_RETURN_IF_ERROR(metadata.size.Set(width,height));if(id<10)metadata.m.SetFloat32Samples();else metadata.m.SetUintSamples(8);metadata.m.xyb_encoded=false;metadata.m.color_encoding=jxl::ColorEncoding::SRGB();
 metadata.m.extra_channel_info.resize(extras);for(auto& extra:metadata.m.extra_channel_info){extra.type=jxl::ExtraChannel::kAlpha;extra.bit_depth.bits_per_sample=8;extra.alpha_associated=id%2;}
 jxl::BitWriter writer(memory);JXL_RETURN_IF_ERROR(jxl::WriteCodestreamHeaders(&metadata,&writer,nullptr));writer.ZeroPadToByte();
 jxl::CompressParams params;params.SetLossless();params.gaborish=jxl::Override::kOff;params.epf=0;params.patches=jxl::Override::kOff;params.speed_tier=jxl::SpeedTier::kThunder;JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&params));
 for(unsigned frame=0;frame<2;++frame){
  const unsigned w=frame?7:width,h=frame?5:height;
  jxl::ImageBundle bundle(memory,&metadata.m);
  JXL_ASSIGN_OR_RETURN(jxl::Image3F image,jxl::Image3F::Create(memory,w,h));
  const unsigned words[]={0,0x80000000,0x7f800000,0xff800000,0x7fc00001,0xffc12345,0x7f800001,0x3f800000,0xbf800000,0x3f000000};
  for(unsigned c=0;c<3;++c)for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){const unsigned raw=words[(x+y*3+c*2+frame*3)%10];if(id<10)memcpy(&image.PlaneRow(c,y)[x],&raw,4);else image.PlaneRow(c,y)[x]=((x*17+y*11+c*29+frame*31)%256)/255.f;}
  JXL_RETURN_IF_ERROR(bundle.SetFromImage(std::move(image),metadata.m.color_encoding));
  std::vector<jxl::ImageF> ec;for(unsigned e=0;e<extras;++e){JXL_ASSIGN_OR_RETURN(jxl::ImageF plane,jxl::ImageF::Create(memory,w,h));for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)plane.Row(y)[x]=((x*17+y*11+frame*31)%200)/255.f;ec.push_back(std::move(plane));}JXL_RETURN_IF_ERROR(bundle.SetExtraChannels(std::move(ec)));
  jxl::FrameInfo info;info.is_last=frame==1;info.save_as_reference=frame?0:1;info.source=1;info.blend=frame!=0;info.blendmode=static_cast<jxl::BlendMode>(id%5);info.clamp=id%2;info.alpha_channel=0;
  if(frame)info.origin={id%2?-2:3,id%2?-1:2};
  bundle.origin=info.origin;bundle.blend=info.blend;bundle.blendmode=info.blendmode;
  const size_t frame_start=writer.BitsWritten()/8;
  jxl::BitWriter encoded(memory);JXL_RETURN_IF_ERROR(jxl::EncodeFrame(memory,params,info,&metadata,bundle,*JxlGetDefaultCms(),nullptr,&encoded,nullptr));encoded.ZeroPadToByte();JXL_RETURN_IF_ERROR(Inject(memory,&metadata,encoded,&writer,id));writer.ZeroPadToByte();
  auto span=writer.GetSpan();jxl::BitReader check(jxl::Bytes(span.data()+frame_start,span.size()-frame_start));jxl::FrameHeader actual(&metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&check,&actual));JXL_RETURN_IF_ERROR(check.Close());
  if(!(actual.flags&jxl::FrameHeader::kNoise)||actual.blending_info.mode!=(frame?info.blendmode:jxl::BlendMode::kReplace)||actual.frame_origin.x0!=info.origin.x0||actual.frame_origin.y0!=info.origin.y0||actual.encoding!=jxl::FrameEncoding::kModular||metadata.m.xyb_encoded||metadata.m.bit_depth.floating_point_sample!=(id<10)||metadata.m.bit_depth.exponent_bits_per_sample!=(id<10?8:0)||actual.loop_filter.gab||actual.loop_filter.epf_iters){fprintf(stderr,"float reference fixture settings were not emitted\n");return false;}
 }
 auto data=writer.GetSpan();JxlDecoder* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,data.data(),data.size());JxlDecoderCloseInput(decoder);
 JxlPixelFormat format={channels,JXL_TYPE_FLOAT,JXL_NATIVE_ENDIAN,0};std::vector<unsigned char> pixels(width*height*channels*4);unsigned frames=0;
 for(;;){const auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(decoder,&format,pixels.data(),pixels.size())!=JXL_DEC_SUCCESS)return false;}else if(status==JXL_DEC_FULL_IMAGE){printf("pub const float_%u_%u=[_]u32{",id,frames);for(size_t i=0;i<pixels.size();i+=4){unsigned bits;memcpy(&bits,pixels.data()+i,4);printf("0x%08x,",bits);}printf("};\n");++frames;}else{fprintf(stderr,"float reference id=%u decoder status=%d\n",id,status);return false;}}
 auto* layers=JxlDecoderCreate(nullptr);JxlDecoderSetCoalescing(layers,JXL_FALSE);JxlDecoderSubscribeEvents(layers,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(layers,data.data(),data.size());JxlDecoderCloseInput(layers);
 unsigned layer_count=0;std::vector<unsigned char> layer;
 for(;;){auto status=JxlDecoderProcessInput(layers);if(status==JXL_DEC_SUCCESS)break;
  if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){size_t size=0;if(JxlDecoderImageOutBufferSize(layers,&format,&size)!=JXL_DEC_SUCCESS)return false;layer.resize(size);if(JxlDecoderSetImageOutBuffer(layers,&format,layer.data(),size)!=JXL_DEC_SUCCESS)return false;}
  else if(status==JXL_DEC_FULL_IMAGE){printf("pub const layer_%u_%u=[_]u32{",id,layer_count++);for(size_t i=0;i<layer.size();i+=4){unsigned bits;memcpy(&bits,layer.data()+i,4);printf("0x%08x,",bits);}printf("};\n");}
  else{fprintf(stderr,"noncoalesced float id=%u status=%d\n",id,status);return false;}
 }
 JxlDecoderDestroy(layers);printf("pub const layers_%u:usize=%u;\n",id,layer_count);
 JxlDecoderDestroy(decoder);printf("pub const bytes_%u=[_]u8{",id);for(auto byte:data)printf("%u,",byte);printf("};\npub const frames_%u:usize=%u;\n",id,frames);return frames!=0;
}
int main(){JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return 1;printf("// Generated by tests/unit/float_noise_oracle.cc.\n");for(unsigned id=0;id<20;++id)if(!Generate(&memory,id))return 2;}
