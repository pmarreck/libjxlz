// Reference storage, cropped layers and all frame blend modes via libjxl.
#include <cstdio>
#include <vector>
#include "jxl/cms.h"
#include "jxl/decode.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_fields.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/enc_patch_dictionary.h"
#include "lib/jxl/enc_toc.h"
#include "lib/jxl/toc.h"
#include "lib/jxl/enc_aux_out.h"
jxl::Status Inject(JxlMemoryManager* memory,jxl::CodecMetadata* metadata,const jxl::BitWriter& original,jxl::BitWriter* output,unsigned id){
 printf("pub const raw_frame_%u=[_]u8{",id);for(auto byte:original.GetSpan())printf("%u,",byte);printf("};\n");
 jxl::BitReader reader(original.GetSpan());jxl::FrameHeader header(metadata);JXL_RETURN_IF_ERROR(jxl::ReadFrameHeader(&reader,&header));
 std::vector<uint32_t> sizes;std::vector<jxl::coeff_order_t> permutation;JXL_RETURN_IF_ERROR(jxl::ReadToc(memory,1,&reader,&sizes,&permutation));JXL_RETURN_IF_ERROR(reader.JumpToByteBoundary());
 const size_t offset=reader.TotalBitsConsumed()/8;JXL_RETURN_IF_ERROR(reader.Close());
 const unsigned extras=(id/8)%2;
 jxl::PatchDictionary dictionary(memory);std::vector<jxl::PatchPosition> positions=id>=16?std::vector<jxl::PatchPosition>{{1,1,0},{2,2,0},{5,5,0}}:std::vector<jxl::PatchPosition>{{2,2,0},{3,3,0},{12,11,0}};std::vector<jxl::PatchReferencePosition> crops={{1,1,1,3,2}};
 std::vector<jxl::PatchBlending> blend;for(unsigned p=0;p<3;++p)for(unsigned c=0;c<=extras;++c)blend.push_back({static_cast<jxl::PatchBlendMode>((id+c)%8),0,p%2!=0});
 jxl::PatchDictionaryEncoder::SetPositions(&dictionary,std::move(positions),std::move(crops),std::move(blend),extras+1);
 std::vector<std::unique_ptr<jxl::BitWriter>> groups;groups.push_back(std::make_unique<jxl::BitWriter>(memory));
 JXL_RETURN_IF_ERROR(jxl::PatchDictionaryEncoder::Encode(dictionary,groups[0].get(),jxl::LayerType::Dictionary,nullptr));
 printf("pub const patch_bits_%u:usize=%zu;\n",id,groups[0]->BitsWritten());
 const auto bytes=original.GetSpan();JXL_RETURN_IF_ERROR(groups[0]->WithMaxBits(sizes[0]*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(size_t i=0;i<sizes[0];++i)groups[0]->Write(8,bytes[offset+i]);return true;}));groups[0]->ZeroPadToByte();
 header.flags|=jxl::FrameHeader::kPatches;JXL_RETURN_IF_ERROR(jxl::WriteFrameHeader(header,output,nullptr));JXL_RETURN_IF_ERROR(jxl::WriteGroupOffsets(groups,{},output,nullptr));
 auto section=groups[0]->GetSpan();JXL_RETURN_IF_ERROR(output->WithMaxBits(section.size()*8,jxl::LayerType::ModularGlobal,nullptr,[&]{for(auto byte:section)output->Write(8,byte);return true;}));return true;
}
jxl::Status Generate(JxlMemoryManager* memory,unsigned id){
 const unsigned width=16,height=12,extras=(id/8)%2,channels=3+extras;
 jxl::CodecMetadata metadata;JXL_RETURN_IF_ERROR(metadata.size.Set(width,height));metadata.m.SetUintSamples(8);metadata.m.xyb_encoded=true;metadata.m.color_encoding=jxl::ColorEncoding::SRGB();
 metadata.m.extra_channel_info.resize(extras);for(auto& extra:metadata.m.extra_channel_info){extra.type=jxl::ExtraChannel::kAlpha;extra.bit_depth.bits_per_sample=8;extra.alpha_associated=id%2;}
 jxl::BitWriter writer(memory);JXL_RETURN_IF_ERROR(jxl::WriteCodestreamHeaders(&metadata,&writer,nullptr));writer.ZeroPadToByte();
 jxl::CompressParams params;params.gaborish=jxl::Override::kOff;params.epf=0;params.patches=jxl::Override::kOff;params.speed_tier=jxl::SpeedTier::kThunder;JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&params));
 for(unsigned frame=0;frame<2;++frame){
  const unsigned w=frame?width:8,h=frame?height:6;
  jxl::ImageBundle bundle(memory,&metadata.m);
  JXL_ASSIGN_OR_RETURN(jxl::Image3F image,jxl::Image3F::Create(memory,w,h));
  for(unsigned c=0;c<3;++c)for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)image.PlaneRow(c,y)[x]=((x*13+y*7+c*29+frame*17)%180)/255.f;
  JXL_RETURN_IF_ERROR(bundle.SetFromImage(std::move(image),metadata.m.color_encoding));
  std::vector<jxl::ImageF> ec;for(unsigned e=0;e<extras;++e){JXL_ASSIGN_OR_RETURN(jxl::ImageF plane,jxl::ImageF::Create(memory,w,h));for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)plane.Row(y)[x]=((x*17+y*11+frame*31)%200)/255.f;ec.push_back(std::move(plane));}JXL_RETURN_IF_ERROR(bundle.SetExtraChannels(std::move(ec)));
  jxl::FrameInfo info;info.is_last=frame==1;info.save_as_reference=frame?0:1;info.alpha_channel=0;
  if(!frame){info.frame_type=jxl::FrameType::kReferenceOnly;info.save_before_color_transform=true;}
  params.modular_mode=frame==0;params.resampling=frame&&id>=16?2:1;params.ec_resampling=params.resampling;
  jxl::BitWriter encoded(memory);JXL_RETURN_IF_ERROR(jxl::EncodeFrame(memory,params,info,&metadata,bundle,*JxlGetDefaultCms(),nullptr,&encoded,nullptr));encoded.ZeroPadToByte();
  if(frame){JXL_RETURN_IF_ERROR(Inject(memory,&metadata,encoded,&writer,id));}else{auto bytes=encoded.GetSpan();JXL_RETURN_IF_ERROR(writer.WithMaxBits(bytes.size()*8,jxl::LayerType::Header,nullptr,[&]{for(auto byte:bytes)writer.Write(8,byte);return true;}));}writer.ZeroPadToByte();
 }
 auto data=writer.GetSpan();JxlDecoder* decoder=JxlDecoderCreate(nullptr);JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE);JxlDecoderSetInput(decoder,data.data(),data.size());JxlDecoderCloseInput(decoder);
 JxlPixelFormat format={channels,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};std::vector<unsigned char> pixels(width*height*channels);unsigned frames=0;
 for(;;){const auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(decoder,&format,pixels.data(),pixels.size())!=JXL_DEC_SUCCESS)return false;}else if(status==JXL_DEC_FULL_IMAGE)++frames;else return false;}
 JxlDecoderDestroy(decoder);printf("pub const bytes_%u=[_]u8{",id);for(auto byte:data)printf("%u,",byte);printf("};\npub const frames_%u:usize=%u;\npub const pixels_%u=[_]u8{",id,frames,id);for(auto byte:pixels)printf("%u,",byte);printf("};\n");return true;
}
int main(){JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return 1;printf("// Generated by tests/unit/patch_padding_oracle.cc.\n");for(unsigned id=0;id<32;++id)if(!Generate(&memory,id))return 2;}
