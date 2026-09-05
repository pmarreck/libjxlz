// Reference storage, cropped layers and all frame blend modes via libjxl.
#include <cstdio>
#include <vector>
#include "jxl/cms.h"
#include "jxl/decode.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_fields.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/enc_toc.h"
#include "lib/jxl/toc.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_splines.h"
jxl::Status Inject(JxlMemoryManager* memory,jxl::CodecMetadata* metadata,const jxl::BitWriter& encoded,jxl::BitWriter* writer,unsigned id){
 jxl::BitReader reader(encoded.GetSpan());jxl::FrameHeader header(metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&reader,&header));
 if(header.flags&(jxl::FrameHeader::kPatches|jxl::FrameHeader::kSplines|jxl::FrameHeader::kNoise)){fprintf(stderr,"unexpected existing features id=%u flags=%llu\n",id,(unsigned long long)header.flags);return false;}
 const auto dim=header.ToFrameDimensions();std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;
 JXL_RETURN_IF_ERROR(jxl::ReadToc(memory,jxl::NumTocEntries(dim.num_groups,dim.num_dc_groups,header.passes.num_passes),&reader,&sizes,&permutation));JXL_RETURN_IF_ERROR(reader.JumpToByteBoundary());
 size_t offset=reader.TotalBitsConsumed()/8;JXL_RETURN_IF_ERROR(reader.Close());
 std::vector<std::unique_ptr<jxl::BitWriter>> groups;auto bytes=encoded.GetSpan();
 for(size_t section=0;section<sizes.size();++section){
  groups.push_back(std::make_unique<jxl::BitWriter>(memory));
  if(section==(permutation.empty()?0:permutation[0])){
   jxl::Spline spline{};spline.control_points={{0,0},{float(std::max(size_t(1),dim.xsize-1)),float(std::max(size_t(1),dim.ysize-1))}};
   spline.color_dct[0][0]=0.01f;spline.color_dct[1][0]=0.1f;spline.color_dct[2][0]=0.2f;spline.sigma_dct[0]=0.7f;
   JXL_ASSIGN_OR_RETURN(auto quantized,jxl::QuantizedSpline::Create(spline,0,0,1));
   jxl::Splines splines(0,{quantized},{spline.control_points[0]});
   JXL_RETURN_IF_ERROR(jxl::EncodeSplines(splines,groups.back().get(),jxl::LayerType::Splines,jxl::HistogramParams(),nullptr));
   if(id%2)JXL_RETURN_IF_ERROR(groups.back()->WithMaxBits(80,jxl::LayerType::Noise,nullptr,[&]{for(unsigned p=0;p<8;++p)groups.back()->Write(10,(id*31+p*71)%1024);return true;}));
  }
  JXL_RETURN_IF_ERROR(groups.back()->WithMaxBits(sizes[section]*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=0;i<sizes[section];++i)groups.back()->Write(8,bytes[offset+i]);return true;}));groups.back()->ZeroPadToByte();offset+=sizes[section];
 }
 if(offset!=bytes.size()){fprintf(stderr,"offset mismatch %zu %zu\n",offset,bytes.size());return false;}header.flags|=jxl::FrameHeader::kSplines;if(id%2)header.flags|=jxl::FrameHeader::kNoise;
 JXL_RETURN_IF_ERROR(jxl::WriteFrameHeader(header,writer,nullptr));JXL_RETURN_IF_ERROR(jxl::WriteGroupOffsets(groups,permutation,writer,nullptr));
 for(auto& group:groups){auto section=group->GetSpan();JXL_RETURN_IF_ERROR(writer->WithMaxBits(section.size()*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(auto byte:section)writer->Write(8,byte);return true;}));}return true;
}
jxl::Status Generate(JxlMemoryManager* memory,unsigned id){
 const unsigned widths[]={17,17,257,273,519,2056,65,65},heights[]={17,3,5,9,17,9,33,65};
 const unsigned width=id<20||id>=28?13:widths[id-20],height=id<20||id>=28?9:heights[id-20],extras=(id%10)/5,channels=3+extras;
 jxl::CodecMetadata metadata;JXL_RETURN_IF_ERROR(metadata.size.Set(width,height));metadata.m.SetUintSamples(8);metadata.m.xyb_encoded=true;metadata.m.color_encoding=jxl::ColorEncoding::SRGB();
 metadata.m.have_animation=id>=28;
 metadata.m.extra_channel_info.resize(extras);for(auto& extra:metadata.m.extra_channel_info){extra.type=jxl::ExtraChannel::kAlpha;extra.bit_depth.bits_per_sample=8;extra.alpha_associated=id%2;}
 jxl::BitWriter writer(memory);JXL_RETURN_IF_ERROR(jxl::WriteCodestreamHeaders(&metadata,&writer,nullptr));writer.ZeroPadToByte();
 jxl::CompressParams params;params.modular_mode=id<10||(id>=20&&id<24)||id==28||id==29;params.gaborish=id%3==0?jxl::Override::kOn:jxl::Override::kOff;params.epf=id==25?0:id%4;params.patches=jxl::Override::kOff;params.resampling=id==26?2:id==27?8:1;params.ec_resampling=params.resampling;params.speed_tier=jxl::SpeedTier::kThunder;JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&params));
 for(unsigned frame=0;frame<(id>=28?4:2);++frame){
  const unsigned w=frame?(id<20?7:std::max(1u,width/2)):width,h=frame?(id<20?5:std::max(1u,height/2)):height;
  jxl::ImageBundle bundle(memory,&metadata.m);
  JXL_ASSIGN_OR_RETURN(jxl::Image3F image,jxl::Image3F::Create(memory,w,h));
  for(unsigned c=0;c<3;++c)for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)image.PlaneRow(c,y)[x]=((x*13+y*7+c*29+frame*17)%180)/255.f;
  JXL_RETURN_IF_ERROR(bundle.SetFromImage(std::move(image),metadata.m.color_encoding));
  std::vector<jxl::ImageF> ec;for(unsigned e=0;e<extras;++e){JXL_ASSIGN_OR_RETURN(jxl::ImageF plane,jxl::ImageF::Create(memory,w,h));for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)plane.Row(y)[x]=((x*17+y*11+frame*31)%200)/255.f;ec.push_back(std::move(plane));}JXL_RETURN_IF_ERROR(bundle.SetExtraChannels(std::move(ec)));
  jxl::FrameInfo info;info.is_last=frame==(id>=28?3:1);info.save_as_reference=frame?0:1;info.source=1;info.blend=frame!=0;info.blendmode=static_cast<jxl::BlendMode>(id%5);info.clamp=id%2;info.alpha_channel=0;
  if(frame)info.origin={id%2?-2:3,id%2?-1:2};
  bundle.origin=info.origin;bundle.blend=info.blend;bundle.blendmode=info.blendmode;
  bundle.duration=id>=28?frame+1:0;
  const size_t frame_start=writer.BitsWritten()/8;
  jxl::BitWriter encoded(memory);JXL_RETURN_IF_ERROR(jxl::EncodeFrame(memory,params,info,&metadata,bundle,*JxlGetDefaultCms(),nullptr,&encoded,nullptr));encoded.ZeroPadToByte();
  JXL_RETURN_IF_ERROR(Inject(memory,&metadata,encoded,&writer,id));writer.ZeroPadToByte();
  auto span=writer.GetSpan();jxl::BitReader check(jxl::Bytes(span.data()+frame_start,span.size()-frame_start));jxl::FrameHeader actual(&metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&check,&actual));JXL_RETURN_IF_ERROR(check.Close());
  if(actual.loop_filter.gab!=(id%3==0)||actual.loop_filter.epf_iters!=unsigned(params.epf)||actual.encoding!=(params.modular_mode?jxl::FrameEncoding::kModular:jxl::FrameEncoding::kVarDCT)||actual.upsampling!=unsigned(params.resampling)){fprintf(stderr,"spline filter/encoding settings were not emitted\n");return false;}
  if(!(actual.flags&jxl::FrameHeader::kSplines)||bool(actual.flags&jxl::FrameHeader::kNoise)!=bool(id%2)||actual.animation_frame.duration!=bundle.duration||actual.blending_info.mode!=(frame?info.blendmode:jxl::BlendMode::kReplace)||actual.frame_origin.x0!=info.origin.x0||actual.frame_origin.y0!=info.origin.y0){fprintf(stderr,"spline fixture settings were not emitted\n");return false;}
 }
 auto data=writer.GetSpan();JxlDecoder* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,data.data(),data.size());JxlDecoderCloseInput(decoder);
 JxlPixelFormat format={channels,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};std::vector<unsigned char> pixels(width*height*channels);unsigned frames=0;
 for(;;){const auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(decoder,&format,pixels.data(),pixels.size())!=JXL_DEC_SUCCESS)return false;}else if(status==JXL_DEC_FULL_IMAGE){if(id>=28){printf("pub const pixels_%u_%u=[_]u8{",id,frames);for(auto byte:pixels)printf("%u,",byte);printf("};\n");}++frames;}else {fprintf(stderr,"spline id=%u decoder status=%d\n",id,int(status));return false;}}
 if(frames!=(id>=28?4:1))return false;
 JxlDecoderDestroy(decoder);printf("pub const bytes_%u=[_]u8{",id);for(auto byte:data)printf("%u,",byte);printf("};\npub const frames_%u:usize=%u;\npub const pixels_%u=[_]u8{",id,frames,id);for(auto byte:pixels)printf("%u,",byte);printf("};\n");return true;
}
int main(){JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return 1;printf("// Generated by tests/unit/spline_frame_oracle.cc.\n");for(unsigned id=0;id<32;++id)if(!Generate(&memory,id))return 2;}
