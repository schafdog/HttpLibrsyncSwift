SIZE=$1
COUNT=$2
FILE=TEST
dd if=/dev/random of=$FILE bs=$SIZE count=$COUNT ;
# Different by block size from previous run
../.build/debug/HTTPClient --debug $FILE http://127.0.0.1:8081 ; diff $FILE ../$FILE
# Check patching of identical
../.build/debug/HTTPClient --debug $FILE http://127.0.0.1:8081 ; diff $FILE ../$FILE
# Nearly 
echo hej >> TEST 
../.build/debug/HTTPClient --debug $FILE http://127.0.0.1:8081 ; diff $FILE ../$FILE
