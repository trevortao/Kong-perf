This code is for improving Kong's forwarding performance when there are a large number of APIs added in Kong which actually affects the scalability of Kong in a great extent. So I call it as High Peformance Kong.
 
With an initial analysis, the main performance bottleneck of Kong lies on the 'Get' operation since all APIs are loaded in Kong memory. For improving this issue, I use a small cache for routine lookups instead of Kong's large cache. 
For the first time, Kong would find the route in the large cache and then set it in the small cache. For the subsequent lookups, Kong would find the corresponding API in the small cache instead of the large one. Currently the small cache's expiry time is set to 600 seconds for a better performance result, which could to refined further as the actual needs. 
When the user updates Kong's API database, the corresponding small cache entry would also be updated(invalidated). Now there are 2 small cache implementations, the difference is at the matched wildcard entries. One of them deals the matched willdcard entry as the normal unicast entry with the request_host as the key; the other implementation uses a separate wildcard part in the small cache, when there is not a match in the unicast part, the wildcard part would be checked. The default here is the first one.
I would set it in another branch from the master but the code is already there as commented out. With the initial ab tests with 20,000 APIs added, it shows the performance is comparable with the small number of APIs in Kong, a typical result is as:

Concurrency Level: 200 
Time taken for tests: 6.293 seconds 
Complete requests: 100000 
Failed requests: 0 
Total transferred: 93816741 bytes 
HTML transferred: 61200000 bytes 
Requests per second: 15891.80 #/sec 
Time per request: 12.585 ms 
Time per request: 0.063 ms 
Transfer rate: 14559.74 [Kbytes/sec] received

Actually I tested with 50,000 APIs with no explicit performance degradation. I also have tested through for possible 200 APIs in the small cache , and sees no explicit performance degradation. The current implementation is based on Kong-0.8.3, I would update it to up-to-date Kong implmentation(0.9.2 now) I think this implementation would need to be further checked and improved with its function and correctness. You could also improve it with your work. If you have done the following work, it is appreciated to let me know.

taozijin@cn.ibm.com
taozj888@163.com
