// Hash all displayed RGBA frames with upstream's public decoder.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "jxl/decode.h"
int main(int argc,char** argv){
 if(argc!=2)return 1;FILE* file=fopen(argv[1],"rb");if(!file)return 2;
 if(fseek(file,0,SEEK_END))return 3;long length=ftell(file);if(length<0||fseek(file,0,SEEK_SET))return 4;
 std::vector<uint8_t> bytes(length);if(fread(bytes.data(),1,bytes.size(),file)!=bytes.size())return 5;fclose(file);
 auto* decoder=JxlDecoderCreate(nullptr);if(!decoder)return 6;
 if(JxlDecoderSubscribeEvents(decoder,JXL_DEC_FULL_IMAGE)!=JXL_DEC_SUCCESS||JxlDecoderSetInput(decoder,bytes.data(),bytes.size())!=JXL_DEC_SUCCESS)return 7;JxlDecoderCloseInput(decoder);
 JxlPixelFormat format={4,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};std::vector<uint8_t> output;unsigned count=0;
 for(;;){auto status=JxlDecoderProcessInput(decoder);if(status==JXL_DEC_SUCCESS)break;
  if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){size_t size;if(JxlDecoderImageOutBufferSize(decoder,&format,&size)!=JXL_DEC_SUCCESS)return 8;output.resize(size);if(JxlDecoderSetImageOutBuffer(decoder,&format,output.data(),size)!=JXL_DEC_SUCCESS)return 9;}
  else if(status==JXL_DEC_FULL_IMAGE){uint64_t hash=1469598103934665603ULL;for(auto byte:output){hash^=byte;hash*=1099511628211ULL;}printf("%s%016llx",count?" ":"",(unsigned long long)hash);++count;}
  else return 10;
 }
 printf("\n");JxlDecoderDestroy(decoder);return count==4?0:11;
}
