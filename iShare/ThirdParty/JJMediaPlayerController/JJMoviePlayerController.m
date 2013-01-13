//
//  JJMoviePlayerController.m
//  iShare
//
//  Created by Jin Jin on 12-12-5.
//  Copyright (c) 2012年 Jin Jin. All rights reserved.
//

#import "SDL.h"
#import "SDL_audio.h"
#import "SDL_video.h"

#import "JJYUVDisplayView.h"
#import "JJMovieAudioPlayer.h"
#import "JJMoviePlayerController.h"
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"


#define SDL_AUDIO_BUFFER_SIZE 1024

#define MAX_AUDIOQ_SIZE (5 * 16 * 1024)
#define MAX_VIDEOQ_SIZE (5 * 256 * 1024)

#define FF_ALLOC_EVENT   (SDL_USEREVENT)
#define FF_REFRESH_EVENT (SDL_USEREVENT + 1)
#define FF_QUIT_EVENT (SDL_USEREVENT + 2)
#define FF_PAUSE_EVENT (SDL_USEREVENT + 3)
#define VIDEO_PICTURE_QUEUE_SIZE 1
#define SDL_AUDIO_BUFFER_SIZE 1024

static AVFrame* AudioFrame = NULL;

#pragma mark - packet queue

typedef struct PacketQueue
{
	AVPacketList *first_pkt, *last_pkt;
	int nb_packets;
	int size;
    __unsafe_unretained NSCondition* cond;
} PacketQueue;

typedef struct VideoPicture
{
	AVPicture *content;
	int width, height; /* source height & width */
	int allocated;
} VideoPicture;

typedef struct VideoState
{
	AVFormatContext *pFormatCtx;
	int             videoStream, audioStream;
	AVStream        *audio_st;
	PacketQueue     audioq;
	uint8_t         audio_buf[(AVCODEC_MAX_AUDIO_FRAME_SIZE * 3) / 2];
	unsigned int    audio_buf_size;
	unsigned int    audio_buf_index;
	AVPacket        audio_pkt;
	AVStream        *video_st;
	PacketQueue     videoq;
    
	VideoPicture    pictq[VIDEO_PICTURE_QUEUE_SIZE];
	int             pictq_size, pictq_rindex, pictq_windex;
    
	char            filename[1024];
	int             quit;
} VideoState;

/* Since we only have one decoding thread, the Big Struct
 can be global in case we need it. */
VideoState *global_video_state;

void PushEvent(Uint32 type, void* data){
    SDL_Event event;
    event.type = type;
    event.user.data1 = data;
    SDL_PushEvent(&event);
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt)
{
	AVPacketList *pkt1;
	if(av_dup_packet(pkt) < 0)
	{
		return -1;
	}
	pkt1 = (AVPacketList *)av_malloc(sizeof(AVPacketList));
	if (!pkt1)
		return -1;
	pkt1->pkt = *pkt;
	pkt1->next = NULL;
    [q->cond lock];
	if (!q->last_pkt)
		q->first_pkt = pkt1;
	else
		q->last_pkt->next = pkt1;
	q->last_pkt = pkt1;
	q->nb_packets++;
	q->size += pkt1->pkt.size;
    [q->cond signal];
    [q->cond unlock];
	return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block)
{
	AVPacketList *pkt1;
	int ret;
    [q->cond lock];
	for(;;)
	{
		if(global_video_state->quit)
		{
			ret = -1;
			break;
		}
		pkt1 = q->first_pkt;
		if (pkt1)
		{
			q->first_pkt = pkt1->next;
			if (!q->first_pkt)
				q->last_pkt = NULL;
			q->nb_packets--;
			q->size -= pkt1->pkt.size;
			*pkt = pkt1->pkt;
			av_free(pkt1);
			ret = 1;
			break;
		}
		else if (!block)
		{
			ret = 0;
			break;
		}
		else
		{
            [q->cond wait];
		}
	}
    [q->cond unlock];
	return ret;
}

int audio_decode_frame(VideoState *is, uint8_t *audio_buf, int buf_size)
{
	int len1;
	AVPacket packet, *pkt = &packet;
    
	for(;;)
	{
        int finished = 0;
        /* next packet */
		if(packet_queue_get(&is->audioq, pkt, 1) < 0)
		{
			return -1;
		}
		while(!finished)
		{
            len1 = avcodec_decode_audio4(is->audio_st->codec, AudioFrame, &finished, pkt);
            /*			len1 = avcodec_decode_audio2(is->audio_st->codec,
                                         (int16_t *)audio_buf, &data_size,
                                         is->audio_pkt_data, is->audio_pkt_size);
             */
			if(len1 < 0)
			{
				/* if error, skip frame */
				break;
			}
			if(is->audio_buf <= 0)
			{
				/* No data yet, get more frames */
				continue;
			}
		}
        
        if (len1 > 0){
            memcpy(audio_buf, AudioFrame->data, AudioFrame->linesize[0]);
        }
        
		if(pkt->data)
			av_free_packet(pkt);
        
		if(is->quit)
		{
			return -1;
		}
		
	}
}

void audio_callback(void *userdata, Uint8 *stream, int len)
{
	VideoState *is = (VideoState *)userdata;
	int len1, audio_size;
    
	while(len > 0)
	{
		if(is->audio_buf_index >= is->audio_buf_size)
		{
			/* We have already sent all our data; get more */
			audio_size = audio_decode_frame(is, is->audio_buf, sizeof(is->audio_buf));
			if(audio_size < 0)
			{
				/* If error, output silence */
				is->audio_buf_size = 1024;
				memset(is->audio_buf, 0, is->audio_buf_size);
			}
			else
			{
				is->audio_buf_size = audio_size;
			}
			is->audio_buf_index = 0;
		}
		len1 = is->audio_buf_size - is->audio_buf_index;
		if(len1 > len)
			len1 = len;
		memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
		len -= len1;
		stream += len1;
		is->audio_buf_index += len1;
	}
}


static Uint32 sdl_refresh_timer_cb(Uint32 interval, void *opaque)
{
    PushEvent(FF_REFRESH_EVENT, opaque);//派发FF_REFRESH_EVENT事件
	return 0; /* 0 means stop timer */
}

/* schedule a video refresh in 'delay' ms */
static void schedule_refresh(VideoState *is, int delay)
{
	//printf("schedule_refresh called:delay--%d/n",delay);
	SDL_AddTimer(delay, sdl_refresh_timer_cb, is);		//sdl_refresh_timer_cb函数在延时delay毫秒后，只会被执行一次，is是sdl_refresh_timer_cb的参数
}

int decode_interrupt_cb(void* opaque)
{
	return (global_video_state && global_video_state->quit);
}

@interface JJMoviePlayerController (){
	AVCodecContext *pVideoCodecCtx;
	AVCodecContext *pAudioCodecCtx;
    NSTimeInterval seekTime;
    VideoState      *inputStream;
    
    BOOL _outputChanged;
    
    BOOL _prepared;
}

@property (nonatomic, copy) NSString* streamPath;

@property (nonatomic, strong) UIView* _internalView;
@property (nonatomic, strong) UIView* _internalBackgroundView;
@property (nonatomic, strong) JJYUVDisplayView* _displayView;
@property (nonatomic, strong) JJMovieAudioPlayer* audioPlayer;

@property (nonatomic, readonly) CGFloat outputWidth;
@property (nonatomic, readonly) CGFloat outputHeight;
//condition
@property (nonatomic, strong) NSCondition* pictq_cond;
@property (nonatomic, strong) NSMutableSet* packetQueueConditions;

//video thread
@property (nonatomic, strong) NSThread* videoThread;
//audio thread
@property (nonatomic, strong) NSThread* audioThread;
//stream decode thread
@property (nonatomic, strong) NSThread* decodeThread;
//event monitor thread
@property (nonatomic, strong) NSThread* monitorThread;

@end

@implementation JJMoviePlayerController

#pragma mark - getter and setter
-(CGSize)natrualSize{
    return CGSizeMake(pVideoCodecCtx->width, pVideoCodecCtx->height);
}

-(NSTimeInterval)playableDuration{
    return 1;
}

-(CGFloat)outputHeight{
    return self._displayView.frame.size.height;
}

-(CGFloat)outputWidth{
    return self._displayView.frame.size.width;
}

-(UIView*)view{
    return self._internalView;
}

-(UIView*)backgroundView{
    return self._internalBackgroundView;
}

-(void)dealloc{
    [self ffmpegAndScaler_release];
    [self SDL_release];
    avcodec_free_frame(&AudioFrame);
}

/**
 init of JJMoviePlayerController with file path
 @param filePath
 @return id
 @exception nil
 */
-(id)initWithFilepath:(NSString*)filePath{
    self = [super init];
    if (self){
        self.streamPath = filePath;
        //conditions for packet queue
        self.packetQueueConditions = [NSMutableSet set];
        [self createViews];
        self.initialPlaybackTime = 0.0;
        inputStream = (VideoState *)av_mallocz(sizeof(VideoState));
        strcpy(inputStream->filename, [filePath cStringUsingEncoding:NSUTF8StringEncoding]);
        DebugLog(@"filename is %s", inputStream->filename);
        inputStream->videoStream= -1;
        inputStream->audioStream= -1;
        
        self.pictq_cond = [[NSCondition alloc] init];
        
        if (global_video_state){

        }
        global_video_state = inputStream;
        
        if (AudioFrame == NULL){
            AudioFrame = avcodec_alloc_frame();
        }
        
        self.audioPlayer = [[JJMovieAudioPlayer alloc] init];
    }
    
    return self;
}

/**
 init of JJMoviePlayerController with input stream
 @param input stream
 @return id
 @exception nil
 */
-(id)initWithInputStream:(NSInputStream*)inputStream{
    self = [super init];
    if (self){

    }
    
    return self;
}

-(void)seekTime:(double)seconds {
	AVRational timeBase = inputStream->video_st->time_base;
	int64_t targetFrame = (int64_t)((double)timeBase.den / timeBase.num * seconds);
	avformat_seek_file(inputStream->pFormatCtx, inputStream->videoStream, targetFrame, targetFrame, targetFrame, AVSEEK_FLAG_FRAME);
	avcodec_flush_buffers(pVideoCodecCtx);
    avcodec_flush_buffers(pAudioCodecCtx);
}

#pragma mark - display video
-(void)video_display:(VideoState*)is
{
	//printf("video_display called/n");
	VideoPicture *vp;
	float aspect_ratio;
    //	int w, h, x, y;
    
	vp = &is->pictq[is->pictq_rindex];
	if(vp->content)
	{
		if(is->video_st->codec->sample_aspect_ratio.num == 0)
		{
			aspect_ratio = 0;
		}
		else
		{
			aspect_ratio = av_q2d(is->video_st->codec->sample_aspect_ratio) *
            is->video_st->codec->width / is->video_st->codec->height;
		}
		if(aspect_ratio <= 0.0)		//aspect_ratio 宽高比
		{
			aspect_ratio = (float)is->video_st->codec->width /
            (float)is->video_st->codec->height;
		}
        
        YUVVideoPicture picture;
        picture.width = vp->width;
        picture.height = vp->height;
        
        for (int i=0; i<4; i++){
            picture.data[i] = vp->content->data[i];
            picture.linesize[i] = vp->content->linesize[i];
        }
        
        [self._displayView setVideoPicture:&picture];
	}
}

#pragma mark - create views
/**
 create views, including display view, background view and overall view
 @param nil
 @return nil
 @exception nil
 */
-(void)createViews{
    self._internalView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self._internalBackgroundView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self._displayView = [[JJYUVDisplayView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self._displayView.backgroundColor = [UIColor whiteColor];
    
    [self._internalView addSubview:self._internalBackgroundView];
    [self._internalView addSubview:self._displayView];
}

#pragma mark - ffmpeg and SDL init/dealloc
/**
 init ffmpeg
 @param nil
 @return success or not
 @exception nil
 */
-(BOOL)ffmpeg_init{
	AVFormatContext *pFormatCtx = NULL;
    
    // Register all formats and codecs
    avcodec_register_all();
    av_register_all();
    
	int video_index = -1;
	int audio_index = -1;
    
	// Open video file
    if (avformat_open_input(&pFormatCtx, inputStream->filename, NULL, NULL) != 0){
		return NO; // Couldn't open file
    }
    // will interrupt blocking functions if we quit!
    pFormatCtx->interrupt_callback.callback = decode_interrupt_cb;
    pFormatCtx->interrupt_callback.opaque = NULL;
    
	inputStream->pFormatCtx = pFormatCtx;
    
	// Retrieve stream information
    if (avformat_find_stream_info(pFormatCtx, NULL) < 0){
        return NO;
    } // Couldn't find stream information
    
	// Dump information about file onto standard error
	av_dump_format(pFormatCtx, 0, inputStream->filename, 0);
    
    // Find the best video stream
    if ((video_index =  av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Cannot find a video stream in the input file\n");
        return NO;
    }
    
    // Find the best audio stream
    if ((audio_index = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0)) < 0){
        av_log(NULL, AV_LOG_ERROR, "Cannot find a video stream in the input file\n");
        return NO;
    }
    
	if(audio_index >= 0)
	{
		[self stream_component_open:audio_index];
	}
	if(video_index >= 0)
	{
        [self stream_component_open:video_index];
	}
    
	if(inputStream->videoStream < 0 || inputStream->audioStream < 0)
	{
		//NSLog(@"%s: could not open codecs/n", is->filename);
        PushEvent(FF_QUIT_EVENT, inputStream);
        
        return NO;
	}
		
    // Get a pointer to the codec context for the video stream
    pVideoCodecCtx = inputStream->video_st->codec;
    // Get a pointer to the codec context for the audio stream
    pAudioCodecCtx = inputStream->audio_st->codec;
    // get sws scale
//    sws_getContext(codecCtx->width, codecCtx->height, codecCtx->pix_fmt,
//                                codecCtx->width, codecCtx->height, PIX_FMT_YUV420P,
//                                SWS_FAST_BILINEAR, NULL, NULL, NULL);
    
    return YES;
}
//release ffmpeg
-(void)ffmpegAndScaler_release{
    // Close the codec
    if (pVideoCodecCtx) avcodec_close(pVideoCodecCtx);
    if (pAudioCodecCtx) avcodec_close(pAudioCodecCtx);
    // Close the video file
    if (inputStream->pFormatCtx) avformat_close_input(&(inputStream->pFormatCtx));
}

/**
 init SDL
 @param nil
 @return success or not
 @exception nil
 */
-(BOOL)SDL_init{
    if (SDL_Init(SDL_INIT_VIDEO|SDL_INIT_TIMER) != 0){
        //NSLog(@"Could not initialize SDL - %s/n", SDL_GetError());
    }
    
    return YES;
}
//release SDL
-(void)SDL_release{
    SDL_Quit();
}

#pragma mark - prepare to play
/**
 Getting prepared for playing
 locate to the correct time
 @param nil
 @return nil
 @exception nil
 */
-(void)prepareToPlay{
    //init ffmpeg and SDL
    if (_prepared == NO){
        
        if ([self ffmpeg_init] == NO || [self SDL_init] == NO){
            //NSLog(@"ffmpeg or SDL init failed");
            return;
        }
        //demux video and audio stream
        //get them ready for play
        [self seekTime:self.initialPlaybackTime];
        //create and run decode thread
        self.decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decode_thread) object:nil];
        //create event mornitor thread
        self.monitorThread = [[NSThread alloc] initWithTarget:self selector:@selector(eventMonitorLoop) object:nil];
        //start threads
        [self.monitorThread start];
        [self.decodeThread start];
        
        _prepared = YES;
    }
}

/**
 clean up all environment for play
 @param nil
 @return nil
 @exception nil
 */
-(void)cleanUpPlay{
    //stop thread
    PushEvent(FF_QUIT_EVENT, nil);
    [self.monitorThread cancel];
    [self.decodeThread cancel];
    [self.videoThread cancel];
}

#pragma mark - play back control
-(void)play{
    [self prepareToPlay];
    //read video/audio/subtitle stream and play
    schedule_refresh(inputStream, 20);
}

-(void)stop{
    PushEvent(FF_QUIT_EVENT, NULL);
    //stop all thread
    [self.videoThread cancel];
    [self.decodeThread cancel];
    [self.monitorThread cancel];
    //release ffmpeg and sdl
    [self ffmpegAndScaler_release];
    [self SDL_release];
}

-(void)pause{
    PushEvent(FF_PAUSE_EVENT, NULL);
}

#pragma mark - thread loop
-(void)eventMonitorLoop{
    @autoreleasepool {
        SDL_Event event;
        while([NSThread currentThread].isCancelled == NO)
        {
            SDL_WaitEvent(&event);
            switch(event.type)
            {
                case FF_QUIT_EVENT:
                    //NSLog(@"FF_QUIT_EVENT recieved");
                case SDL_QUIT:
                    //NSLog(@"SDL_QUIT recieved");
                    inputStream->quit = 1;
                    SDL_Quit();
                    return;
                    break;
                case FF_ALLOC_EVENT:
                    [self alloc_picture:event.user.data1];
                    break;
                case FF_REFRESH_EVENT:
                    [self video_refresh_timer:event.user.data1];
                    break;
                case FF_PAUSE_EVENT:
                    break;
                default:
                    break;
            }
        }
    }
}

#pragma mark - decode thread loop
-(int)decode_thread
{
    @autoreleasepool {
        VideoState* is = inputStream;
        
        // main decode loop
        while([[NSThread currentThread] isCancelled] == NO)
        {
            AVPacket packet, *pkt = &packet;
            //        AVPacket *pkt = (AVPacket*)av_malloc(sizeof(AVPacket));
            av_new_packet(pkt, 1);
            
            if(is->quit)
            {
                break;
            }
            // seek stuff goes here
            if(is->audioq.size > MAX_AUDIOQ_SIZE ||
               is->videoq.size > MAX_VIDEOQ_SIZE)
            {
                SDL_Delay(10);
                continue;
            }
            if(av_read_frame(is->pFormatCtx, pkt) < 0)
            {
                if(is->pFormatCtx->pb->error == 0)
                {
                    SDL_Delay(100); /* no error; wait for user input */
                    continue;
                }
                else
                {
                    break;
                }
            }
            // Is this a packet from the video stream?
            if(pkt->stream_index == is->videoStream)
            {
                //NSLog(@"put video packet");
                packet_queue_put(&is->videoq, pkt);
            }
            else if(pkt->stream_index == is->audioStream)
            {
                //NSLog(@"put audio packet");
                packet_queue_put(&is->audioq, pkt);
            }
            else
            {
                av_free_packet(pkt);
            }
            
        }
        /* all done - wait for it */
        while(!is->quit)
        {
            SDL_Delay(100);
        }
        
        PushEvent(FF_QUIT_EVENT, is);
    }
    
    return 0;
}

#pragma mark - video thread
-(int)video_thread{
    @autoreleasepool {
        int len1, frameFinished = 0;
        AVFrame *pFrame = avcodec_alloc_frame();
        
        while([[NSThread currentThread] isCancelled] == NO)
        {
            DebugLog(@"video loop");
            //        AVPacket pkt1, *packet = &pkt1;
            AVPacket* packet = (AVPacket*)av_malloc(sizeof(AVPacket));
            av_new_packet(packet, 1);
            DebugLog(@"start getting packets from video queue");
            if(packet_queue_get(&inputStream->videoq, packet, 1) < 0)
            {
                // means we quit getting packets
                DebugLog(@"quit getting packets");
                break;
            }
            DebugLog(@"end getting packets from video queue");
            // Decode video frame
            len1 = avcodec_decode_video2(inputStream->video_st->codec, pFrame, &frameFinished, packet);
            
            // Did we get a video frame?
            if(frameFinished)
            {
                DebugLog(@"enqueue frame to stream");
                if([self queue_picture:inputStream withFrame:pFrame] < 0)
                {
                    DebugLog(@"enqueue failed");
                    break;
                }
                DebugLog(@"end enqueuing frame to stream");
                frameFinished = 0;
            }
            av_free_packet(packet);
            av_free(packet);
            DebugLog(@"packet is freed");
        }
        
        av_free(pFrame);
    }
	
	return 0;
}


#pragma mark - audio thread
-(int)audio_thread{
    @autoreleasepool {
        int len1, frameFinished = 0;
        AVFrame *pFrame = avcodec_alloc_frame();
        AVCodecContext* codec = inputStream->audio_st->codec;
        //caculate sample buffer
        int nb_channels = av_get_channel_layout_nb_channels(AV_CH_LAYOUT_STEREO);
        BOOL needResample = (codec->channels > nb_channels || (codec->sample_fmt != AV_SAMPLE_FMT_U8 || codec->sample_fmt != AV_SAMPLE_FMT_S16) );
        int alFormat;
        if (needResample){
            alFormat = AL_FORMAT_STEREO16;
        }else{
            alFormat = [self openALSampleFormatFromCodec:inputStream->audio_st->codec];
        }
        int avFormat = AV_SAMPLE_FMT_S16;
        int sampleRate = 44100;
        //resample context
        SwrContext* ctx = swr_alloc_set_opts(NULL,
                                             //                                         av_get_channel_layout("stereo"), avFormat, sampleRate,
                                             av_get_channel_layout("stereo"), avFormat, sampleRate,
                                             codec->channel_layout, codec->sample_fmt, codec->sample_rate, 0, NULL);
        swr_init(ctx);
        
        while([[NSThread currentThread] isCancelled] == NO)
        {
            DebugLog(@"audio loop");
            AVPacket pkt1, *packet = &pkt1;
            av_new_packet(packet, 1);
            DebugLog(@"start getting packets from audio queue");
            if(packet_queue_get(&inputStream->audioq, packet, 1) < 0)
            {
                // means we quit getting packets
                DebugLog(@"quit getting audio packets");
                break;
            }
            DebugLog(@"end getting packets from audio queue");
            // Decode video frame
            len1 = avcodec_decode_audio4(codec, pFrame, &frameFinished, packet);
            
            // Did we get a audio frame?
            if(frameFinished)
            {
                if (needResample){
                    uint8_t* buffer[SWR_CH_MAX] = {NULL};
                    int samplePerChannel = pFrame->nb_samples/pFrame->channels;
                    int sampleSize = av_get_bytes_per_sample(avFormat);
                    int bufferSize = av_samples_get_buffer_size(NULL, nb_channels, samplePerChannel,
                                                                avFormat, 1);
                    
                    buffer[0] = malloc(bufferSize);
                    //resmaple audio
                    int nb_output = swr_convert(ctx,
                                                (uint8_t**)&buffer, samplePerChannel,
                                                (const uint8_t**)pFrame->data, pFrame->nb_samples/pFrame->channels);
                    // Drain buffer
                    //                int temp;
                    //                while ((temp = swr_convert(ctx, (uint8_t**)&buffer, samplePerChannel, NULL, 0)) > 0){
                    //                    nb_output += temp;
                    //                }
                    
                    //send audio data to open al
                    [self.audioPlayer moreData:buffer[0]
                                        length:nb_output * nb_channels * sampleSize
                                     frequency:sampleRate
                                        format:alFormat];
                    //                swr_convert(ctx, NULL, 0, (const uint8_t**)pFrame->extended_data, pFrame->nb_samples);
                    
                    free(buffer[0]);
                }else{
                    [self.audioPlayer moreData:pFrame->data[0]
                                        length:pFrame->linesize[0]
                                     frequency:pFrame->sample_rate
                                        format:alFormat];
                }
                frameFinished = 0;
            }
            av_free_packet(packet);
            DebugLog(@"packet is freed");
        }
        
        swr_free(&ctx);
        av_free(pFrame);
    }
	
	return 0;
}

-(int)openALSampleFormatFromCodec:(AVCodecContext*)context{
    int format;
    //play audio
    int channels = context->channels;
    int sample_fmt = context->sample_fmt;
    if (channels == 1){
        format = AL_FORMAT_MONO16;
        if (sample_fmt == AV_SAMPLE_FMT_U8 || sample_fmt == AV_SAMPLE_FMT_U8P){
            format = AL_FORMAT_MONO8;
        }else if (sample_fmt == AV_SAMPLE_FMT_S16 || sample_fmt == AV_SAMPLE_FMT_S16P){
            format = AL_FORMAT_MONO16;
        }
    }else{
        format = AL_FORMAT_STEREO16;
        if (sample_fmt == AV_SAMPLE_FMT_U8 || sample_fmt == AV_SAMPLE_FMT_U8P){
            format = AL_FORMAT_STEREO8;
        }else if (sample_fmt == AV_SAMPLE_FMT_S16 || sample_fmt == AV_SAMPLE_FMT_S16P){
            format = AL_FORMAT_STEREO16;
        }
    }
    
    return format;
}

#pragma mark - open stream
-(int)stream_component_open:(int)stream_index{
	AVFormatContext *pFormatCtx = inputStream->pFormatCtx;
	AVCodecContext *codecCtx;
	AVCodec *codec;
    
	if(stream_index < 0 || stream_index >= pFormatCtx->nb_streams)
	{
		return -1;
	}
    
	// Get a pointer to the codec context for the video stream
	codecCtx = pFormatCtx->streams[stream_index]->codec;
    
	codec = avcodec_find_decoder(codecCtx->codec_id);
    AVDictionary* opt = NULL;
	if(!codec || (avcodec_open2(codecCtx, codec, &opt) < 0))
	{
		fprintf(stderr, "Unsupported codec!/n");
		return -1;
	}
    
	switch(codecCtx->codec_type)
	{
        case AVMEDIA_TYPE_AUDIO:
            inputStream->audioStream = stream_index;
            inputStream->audio_st = pFormatCtx->streams[stream_index];
            inputStream->audio_buf_size = 0;
            inputStream->audio_buf_index = 0;
//            inputStream->audio_st->codec->request_channel_layout = av_get_channel_layout("stereo");
            memset(&inputStream->audio_pkt, 0, sizeof(inputStream->audio_pkt));
            [self packet_queue_init:&(inputStream->audioq)];
            //start audio thread
            self.audioThread = [[NSThread alloc] initWithTarget:self selector:@selector(audio_thread) object:nil];
            [self.audioThread start];
            break;
        case AVMEDIA_TYPE_VIDEO:
            inputStream->videoStream = stream_index;
            inputStream->video_st = pFormatCtx->streams[stream_index];
            [self packet_queue_init:&(inputStream->videoq)];
            //start video decode thread
            self.videoThread = [[NSThread alloc] initWithTarget:self selector:@selector(video_thread) object:nil];
            [self.videoThread start];
            break;
        default:
            break;
	}
    
    return 0;
}

-(void)alloc_picture:(void *)userdata{
	VideoState *is = (VideoState *)userdata;
	VideoPicture *vp;
    
	vp = &is->pictq[is->pictq_windex];
	if(vp->content)
	{
		// we already have one make another, bigger/smaller
        avpicture_free(vp->content);
	}else{
        vp->content = (AVPicture*)av_mallocz(sizeof(AVPicture));
    }
	
    AVCodecContext* codec = is->video_st->codec;
    avpicture_alloc(vp->content, codec->pix_fmt, codec->width, codec->height);
	vp->width = is->video_st->codec->width;
	vp->height = is->video_st->codec->height;
    [self.pictq_cond lock];
	vp->allocated = 1;
    [self.pictq_cond signal];
    [self.pictq_cond unlock];
}

-(void)video_refresh_timer:(void *)userdata{
	VideoState *is = (VideoState *)userdata;
	VideoPicture *vp;
    
	if(is->video_st)
	{
		if(is->pictq_size == 0)
		{
			schedule_refresh(is, 1);
		}
		else
		{
			vp = &is->pictq[is->pictq_rindex];
			/* Now, normally here goes a ton of code
             about timing, etc. we're just going to
             guess at a delay for now. You can
             increase and decrease this value and hard code
             the timing - but I don't suggest that ;)
             We'll learn how to do it for real later.
             */
			schedule_refresh(is, 1/60);
            
			/* show the picture! */
            DebugLog(@"show picture!");
            [self video_display:is];
            
			/* update queue for next picture! */
			if(++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
			{
				is->pictq_rindex = 0;
			}
            [self.pictq_cond lock];
			is->pictq_size--;
            [self.pictq_cond signal];
            [self.pictq_cond unlock];
		}
	}
	else
	{
		schedule_refresh(is, 100);
	}
}

-(void)packet_queue_init:(PacketQueue*)q{
	memset(q, 0, sizeof(PacketQueue));
    NSCondition* condition = [[NSCondition alloc] init];
    [self.packetQueueConditions addObject:condition];
	q->cond = condition;
}

#pragma mark - queue audio
-(void)queue_audio:(VideoState*)is withFrame:(AVFrame*)pFrame{
    
}

#pragma mark - queue picture
-(int)queue_picture:(VideoState*)is withFrame:(AVFrame*)pFrame{
	//printf("queue_picture called/n");
    //modify
    //queue decoded frame
	VideoPicture *vp;
    
	/* wait until we have space for a new pic */
    DebugLog(@"lock pictq_cond");
    [self.pictq_cond lock];
	while(is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE &&
          !is->quit){
        DebugLog(@"waiting for pictq_cond");
        DebugLog(@"pictq_size is %d", is->pictq_size);
        [self.pictq_cond wait];
	}
    [self.pictq_cond unlock];
    
	if(is->quit){
		return -1;
    }
    
	// windex is set to 0 initially
	vp = &is->pictq[is->pictq_windex];
	
    //add picture data to vp
    //need to modify vp
	/* allocate or resize the buffer! */
	if(!vp->content ||
       vp->width != is->video_st->codec->width ||
       vp->height != is->video_st->codec->height)
	{
        
		vp->allocated = 0;
        //allocate picture
        [self alloc_picture:inputStream];
        
		/* wait until we have a picture allocated */
        [self.pictq_cond lock];
		while(!vp->allocated && !is->quit){
            DebugLog(@"waiting for picture queue");
            [self.pictq_cond wait];	//没有得到消息时解锁，得到消息后加锁，和SDL_CondSignal配对使用
            DebugLog(@"picture queue waited");
		}
        [self.pictq_cond unlock];
		if(is->quit)
		{
			return -1;
		}
	}
	/* We have a place to put our picture on the queue */
    
	if(vp->content)
	{
        av_picture_copy(vp->content, (const AVPicture*)pFrame, is->video_st->codec->pix_fmt, is->video_st->codec->width, is->video_st->codec->height);
		/* now we inform our display thread that we have a pic ready */
		if(++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE)
		{
			is->pictq_windex = 0;
		}
        [self.pictq_cond lock];
		is->pictq_size++;
        [self.pictq_cond unlock];
	}
	return 0;
}

@end