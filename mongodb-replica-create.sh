# For port 27019
docker run -d \
  --name mongodb \
  -p 27019:27017 \
  mongo:latest \
  --replSet rs0 \
  --bind_ip_all

sleep 5

docker exec mongodb mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:27017'}]})"

# mongodb shell
# mongodb://localhost:27019/?directConnection=true

# for application
# mongodb://localhost:27019/db_name_will_be_here?directConnection=true
