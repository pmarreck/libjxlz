// Complete filter-stage outputs from the retained upstream render pipeline.
#include <cmath>
#include <cstdio>
#include <vector>
#include "lib/jxl/image_ops.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/loop_filter.h"
#include "lib/jxl/render_pipeline/stage_gaborish.h"
#include "lib/jxl/render_pipeline/stage_epf.h"
#include "lib/jxl/render_pipeline/render_pipeline_stage.h"

jxl::Status Generate(JxlMemoryManager* memory,size_t id) {
	const size_t width=id==0?1:id==1?7:17,height=id==0?3:id==1?9:17;
	const size_t pad=jxl::kRenderPipelineXOffset;
	JXL_ASSIGN_OR_RETURN(jxl::Image3F input,jxl::Image3F::Create(memory,width+2*pad,height+6));
	JXL_ASSIGN_OR_RETURN(jxl::Image3F output,jxl::Image3F::Create(memory,width+2*pad,height));
	for(size_t c=0;c<3;++c)for(size_t y=0;y<height+6;++y)for(size_t x=0;x<width+2*pad;++x){
		const size_t mx=jxl::Mirror(static_cast<int64_t>(x)-pad,width),my=jxl::Mirror(static_cast<int64_t>(y)-3,height);
		const int sample=static_cast<int>((mx*13+my*17+c*11)%37)-18;
		input.PlaneRow(c,y)[x]=sample/(c==0?8192.f:c==1?1024.f:2048.f);
	}
	const size_t bw=(width+7)/8,bh=(height+7)/8;
	JXL_ASSIGN_OR_RETURN(jxl::ImageF sigma,jxl::ImageF::Create(memory,bw+4,bh+4));
	for(size_t y=0;y<bh+4;++y)for(size_t x=0;x<bw+4;++x){
		const size_t mx=jxl::Mirror(static_cast<int64_t>(x)-2,bw),my=jxl::Mirror(static_cast<int64_t>(y)-2,bh);
		const float values[]={-0.75f,-1.5f,-4.f};sigma.Row(y)[x]=values[(mx+my)%3];
	}
	jxl::LoopFilter lf;
	lf.epf_iters=3;
	if(id==3){
		lf.gab_x_weight1=.125f;lf.gab_x_weight2=.03125f;
		lf.gab_y_weight1=-.0625f;lf.gab_y_weight2=.125f;
		lf.gab_b_weight1=.25f;lf.gab_b_weight2=-.03125f;
		lf.epf_channel_scale[0]=32;lf.epf_channel_scale[1]=4;lf.epf_channel_scale[2]=2;
		lf.epf_pass0_sigma_scale=.75f;lf.epf_pass2_sigma_scale=4;
		lf.epf_border_sad_mul=.5f;
	}
	printf("pub const input_%zu = [_]i32{",id);
	for(size_t c=0;c<3;++c)for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x)printf("%d,",static_cast<int>(input.PlaneRow(c,y+3)[x+pad]*65536));
	printf("};\n");
	for(size_t kind=0;kind<4;++kind){
		auto stage=kind==0?jxl::GetGaborishStage(lf):jxl::GetEPFStage(lf,sigma,static_cast<jxl::EpfStage>(kind-1));
		const int border=kind==0?1:4-kind;
		for(size_t y=0;y<height;++y){
			jxl::RenderPipelineStage::RowInfo rows(3),out(3);
			for(size_t c=0;c<3;++c){for(int dy=-border;dy<=border;++dy)rows[c].push_back(input.PlaneRow(c,y+3+dy));out[c].push_back(output.PlaneRow(c,y));}
			JXL_RETURN_IF_ERROR(stage->ProcessRow(rows,out,0,width,0,y,0));
		}
		printf("pub const output_%zu_%zu = [_]i32{",id,kind);
		for(size_t c=0;c<3;++c)for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x)printf("%d,",static_cast<int>(std::llround(output.PlaneRow(c,y)[x+pad]*(1<<24))));
		printf("};\n");
	}
	return true;
}
int main(){JxlMemoryManager memory;if(!jxl::MemoryManagerInit(&memory,nullptr))return 1;printf("// Upstream filter stages, tests/unit/filter_oracle.cc. Input 2^16, output 2^24.\n");for(size_t id=0;id<4;++id)if(!Generate(&memory,id))return 2;}
