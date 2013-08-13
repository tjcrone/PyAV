import sys
import av


source = sys.argv[1]
source_video = av.open(source)


streams = [s for s in source_video.streams if s.type == b'video']
audio_streams = [s for s in source_video.streams if s.type == b'audio']
streams = [streams[0]]

if audio_streams:
    streams.append(audio_streams[0])
    

encode_video = av.open("./sandbox/encode_example.mp4", 'w')


video_stream = encode_video.add_stream("h264",streams[0].base_frame_rate)
audio_stream = encode_video.add_stream("mp3")

codec = video_stream.codec
print "name", codec.name
print "bit_rate", codec.bit_rate
print "time_base", codec.time_base
print "pix_fmt", codec.pix_fmt
print  "size %ix%i" % (codec.width, codec.height)
print "gop_size", codec.gop_size

print "Audio"
print "sample format", audio_stream.codec.sample_fmt
print "channel layout", audio_stream.codec.channel_layout
print "channels", audio_stream.codec.channels
#audio_stream.codec.channel_layout = "mono"

print "channel layout",  audio_stream.codec.channel_layout 
print "channels", audio_stream.codec.channels

#audio_stream.codec.sample_fmt = "s16p"
#audio_stream.codec.channel_layout  = "mono"
#audio_stream.codec.channels = 2
#audio_stream.codec.sample_fmt = 's16p'
print "channel layout", audio_stream.codec.channel_layout 

#raise Exception('stop')
encode_video.dump()

#raise Exception()



frame_count = 0

for packet in source_video.demux(streams):
    for frame in packet.decode():
        
        if packet.stream.type == b'audio':
            #print frame
            #print frame.samples, frame.sample_fmt, frame.channels, frame.channel_layout
            encoded_packet = audio_stream.encode(frame)
            if encoded_packet:
                encode_video.mux(encoded_packet)
        else:
            #print frame.pix_fmt
            frame_count += 1
            #print frame_count
            encoded_packet = video_stream.encode(frame)
            if encoded_packet:
                pass
                encode_video.mux(encoded_packet)
            print frame_count
        
    if frame_count > 1000:
        break


while True:
    packet =  audio_stream.encode()
    print "flushed out audio packet", packet
    if packet:
        encode_video.mux(packet)
    else:

        break

while True:
    packet =  video_stream.encode()
    print "flushed out video packet", packet
    if packet:
        encode_video.mux(packet)
    else:
        break

  
         
encode_video.close()
