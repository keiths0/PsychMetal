// Reusable GPU image-processing chains; included by the shared Metal engine.
// SPDX-License-Identifier: MIT
struct PMImageUniform {uint32_t kind=0,channels=4,premultiplied=0,radius=0;float v[32]{};};
struct PMImageWorkspace {PMTextureRef textures[2];};
struct PMImagePipeline {std::vector<PMImageUniform> passes;std::vector<std::shared_ptr<PMImageWorkspace>> workspaces;};
static std::map<uint64_t,std::shared_ptr<PMImagePipeline>> imagePipelines;
static id<MTLRenderPipelineState> imageProcessingPipeline=nil;
static uint64_t nextImagePipeline=1;
static void closeImagePipelines(){imagePipelines.clear();imageProcessingPipeline=nil;}
uint64_t pm::createImagePipeline(const pm::ArrayView &operations) {
    if(!device||closing)fail("CreateImagePipeline needs an open graphics session.");
    if(operations.type!=pm::ScalarType::Float64||operations.ndim!=2||operations.shape[1]!=32||
       operations.shape[0]<1||operations.shape[0]>32||!operations.data)fail("An image pipeline needs 1..32 rows of 32 doubles.");
    if(imagePipelines.size()>=64||nextImagePipeline>=PM_MAX_ID)fail("Image pipeline capacity exceeded.");
    auto pipeline=std::make_shared<PMImagePipeline>();pipeline->passes.reserve(operations.shape[0]*2);
    for(size_t i=0;i<operations.shape[0];i++) {
        double row[32];for(size_t c=0;c<32;c++){row[c]=viewAt(operations,i,c);if(!std::isfinite(row[c]))fail("Pipeline parameters must be finite.");}
        const int kind=(int)pm::checkUnsigned(row[0],"operation",6);
        if(kind==1) {
            const double sigma=row[1];if(sigma<.1||sigma>10)fail("Gaussian sigma must be .1..10 pixels.");
            const int radius=row[2]==0?(int)std::ceil(3*sigma):(int)pm::checkUnsigned(row[2],"radius",31);
            if(radius<1)fail("Gaussian radius must be 1..31.");
            PMImageUniform u;u.kind=1;u.radius=(uint32_t)radius;double sum=0;
            for(int k=0;k<=radius;k++){u.v[k]=(float)std::exp(-.5*k*k/(sigma*sigma));sum+=u.v[k]*(k?2:1);}
            for(int k=0;k<=radius;k++)u.v[k]/=(float)sum;
            pipeline->passes.push_back(u);u.kind=2;pipeline->passes.push_back(u);
        } else {
            PMImageUniform u;u.kind=(uint32_t)kind;
            for(size_t c=1;c<32;c++){if(std::abs(row[c])>10000)fail("Image pipeline parameters exceed their numeric limit.");u.v[c-1]=(float)row[c];}
            if(kind==3){if(row[1]<-16||row[1]>16)fail("Exposure must be -16..16 stops.");u.v[0]=(float)std::exp2(row[1]);}
            else if(kind==4) {} // row-major 3x4 RGB matrix plus bias
            else if(kind==5) {
                auto size=pm::checkUnsigned(row[1],"convolution width",5);
                if(size<1||!(size&1))fail("Convolution kernel must be odd square, at most 5x5.");
                u.radius=(uint32_t)size;
            } else if(kind!=6)fail("Unknown image operation: use Gaussian, exposure, color matrix, convolution or affine.");
            pipeline->passes.push_back(u);
        }
    }
    if(!imageProcessingPipeline) {
        NSError *error=nil;
        imageProcessingPipeline=makePipeline(@"evmain",@"ifmain",MTLPixelFormatRGBA16Float,pm::internal::blendFor(PM_BLEND_COPY,false,false),&error);
        if(!imageProcessingPipeline)failWith(pm::kErrPipeline,"Could not create image pipeline: %s",error.localizedDescription.UTF8String);
    }
    auto handle=nextImagePipeline++;imagePipelines.emplace(handle,std::move(pipeline));return handle;
}
void pm::closeImagePipeline(uint64_t handle) {
    if(!imagePipelines.erase(handle))fail("Invalid or closed image pipeline.");
}
uint64_t pm::processImage(uint64_t handle,uint64_t sourceHandle,uint64_t destination) {
    if(!device||closing)fail("ProcessImage needs an open graphics session.");
    pthread_mutex_lock(&lock);bool failed=asynchronousGpuFailure;pthread_mutex_unlock(&lock);
    if(failed)fail("Image processing GPU session failed; Close and reopen.");
    auto found=imagePipelines.find(handle);if(found==imagePipelines.end())fail("Invalid or closed image pipeline.");
    auto pipeline=found->second;
    const int sourceSlot=textureSlot(sourceHandle);auto source=userTextures[sourceSlot];
    int slot=-1;
    if(destination){slot=textureSlot(destination);if(userTextures[slot]->offscreen)fail("Pipeline destination must be an ordinary image texture.");}
    else {for(int i=0;i<PM_MAX_TEXTURES;i++)if(!userTextures[i]){slot=i;break;}if(slot<0||nextTextureHandle>=PM_MAX_ID)fail("No free texture handles.");}
    const size_t w=source->width,h=source->height;
    const uint64_t workspaceBytes=(uint64_t)w*h*16;
    if(workspaceBytes>256ull*1024*1024)fail("Image workspace exceeds 256 MiB; use a smaller image.");
    std::shared_ptr<PMImageWorkspace> workspace;
    auto idleWorkspace=[&]() -> std::shared_ptr<PMImageWorkspace> {
        for(auto &candidate:pipeline->workspaces) {
            bool idle=candidate->textures[0]->width==w&&candidate->textures[0]->height==h;
            for(auto &t:candidate->textures)idle&=t.use_count()==(userTextures[slot]==t?2:1);
            if(idle)return candidate;
        }
        return {};
    };
    workspace=idleWorkspace();
    if(!workspace) {
        // Drop idle workspaces of obsolete dimensions before enforcing the budget.
        auto &pool=pipeline->workspaces;
        pool.erase(std::remove_if(pool.begin(),pool.end(),[&](const auto &x){return x->textures[0].use_count()==1&&x->textures[1].use_count()==1;}),pool.end());
        uint64_t bytes=workspaceBytes;
        for(auto &x:pool)bytes+=(uint64_t)x->textures[0]->width*x->textures[0]->height*16;
        if(pool.size()>=4||bytes>256ull*1024*1024) {
            // A large image may fit only one workspace. Wait for its GPU users
            // instead of failing merely because the previous Flip returned early.
            pthread_mutex_lock(&lock);double deadline=CACurrentMediaTime()+2;
            while(!(workspace=idleWorkspace())&&!asynchronousGpuFailure)
                if(waitRelative(deadline)==ETIMEDOUT)break;
            bool failed=asynchronousGpuFailure;pthread_mutex_unlock(&lock);
            if(failed)fail("Image processing GPU session failed; Close and reopen.");
            if(!workspace)fail("Image workspace pool is busy/full; Flip and release unused output textures before processing again.");
        }
        if(!workspace) {
        workspace=std::make_shared<PMImageWorkspace>();
        for(auto &t:workspace->textures) {
            auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
            td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
            id<MTLTexture> texture=[device newTextureWithDescriptor:td];if(!texture)fail("Could not allocate image pipeline workspace.");
            t=std::make_shared<PMTextureResource>();t->texture=texture;t->width=w;t->height=h;t->channels=4;t->gpuOnly=true;t->pipelineOutput=true;
            textureAllocations++;
        }
        pool.push_back(workspace);
        }
    }
    @autoreleasepool {
        flushTarget(); // pending offscreen drawing is committed before it is sampled
        id<MTLCommandBuffer> cb=[queue commandBuffer];if(!cb)fail("Could not create image processing command buffer.");
        auto keep=std::make_shared<std::vector<PMTextureRef>>();keep->reserve(3);
        keep->push_back(source);for(auto &t:workspace->textures)keep->push_back(t);
        PMTextureRef input=source;
        for(size_t i=0;i<pipeline->passes.size();i++) {
            auto output=workspace->textures[i%2];auto u=pipeline->passes[i];u.channels=(uint32_t)input->channels;u.premultiplied=input->offscreen;
            auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=output->texture;
            pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:pass];
            if(!encoder)fail("Could not encode image pipeline; destination is unchanged.");
            [encoder setRenderPipelineState:imageProcessingPipeline];[encoder setFragmentTexture:input->texture atIndex:0];
            [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];input=output;
        }
        watchRender(cb,0);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){keep->clear();pthread_mutex_lock(&lock);pthread_cond_broadcast(&cond);pthread_mutex_unlock(&lock);}];
        [cb commit];
        userTextures[slot]=input;texturePools[slot].clear();
        if(!destination){textureHandles[slot]=nextTextureHandle++;texturesCreated++;}
        return textureHandles[slot];
    }
}
