import sys
import av


source = sys.argv[1]

encode_video = av.open("./sandbox/encode_example.mp4", 'w')


stream = encode_video.add_stream("h264")

codec = stream.codec
print "name", codec.name
print "bit_rate", codec.bit_rate
print "time_base", codec.time_base
print "pix_fmt", codec.pix_fmt
print  "size %ix%i" % (codec.width, codec.height)
print "gop_size", codec.gop_size



encode_video.begin_encoding()
encode_video.dump()

source_video = av.open(source)


streams = [s for s in source_video.streams if s.type == b'video']
streams = [streams[0]]

frame_count = 0

for packet in source_video.demux(streams):
    for frame in packet.decode():
        
        
        frame_count += 1
        stream.encode(frame)
        
    if frame_count > 1000:
        break
        
encode_video.close()