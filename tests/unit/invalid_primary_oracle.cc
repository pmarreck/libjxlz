// Verify the retained metadata mutations against upstream's public decoder.
// Usage: invalid_primary_oracle src/lib/codec/invalid_primary_fixture.zig
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "jxl/decode.h"
int main(int argc,char** argv){
 if(argc!=2)return 1;
 FILE* input=fopen(argv[1],"rb");if(!input)return 2;
 char line[8192];unsigned count=0;
 while(fgets(line,sizeof(line),input)){
  unsigned id;if(sscanf(line,"pub const invalid_%u=",&id)!=1)continue;
  if(id!=count)return 3;
  char* cursor=strchr(line,'{');if(!cursor)return 4;++cursor;
  std::vector<unsigned char> bytes;
  while(*cursor!='}'){
   char* end=nullptr;const unsigned long value=strtoul(cursor,&end,10);
   if(end==cursor||*end!=','||value>255)return 5;
   bytes.push_back(static_cast<unsigned char>(value));cursor=end+1;
  }
  auto* dec=JxlDecoderCreate(nullptr);if(!dec)return 6;
  if(JxlDecoderSubscribeEvents(dec,JXL_DEC_FULL_IMAGE)!=JXL_DEC_SUCCESS||JxlDecoderSetInput(dec,bytes.data(),bytes.size())!=JXL_DEC_SUCCESS)return 7;
  JxlDecoderCloseInput(dec);
  auto status=JxlDecoderProcessInput(dec);std::vector<unsigned char> pixels(19*13*3);JxlPixelFormat format={3,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};
  if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderSetImageOutBuffer(dec,&format,pixels.data(),pixels.size())!=JXL_DEC_SUCCESS)return 8;status=JxlDecoderProcessInput(dec);}
  JxlDecoderDestroy(dec);if(status!=JXL_DEC_ERROR){fprintf(stderr,"invalid color id=%u accepted with status=%d\n",id,status);return 9;}
  ++count;
 }
 if(ferror(input)||count!=5)return 10;
 fclose(input);return 0;
}
