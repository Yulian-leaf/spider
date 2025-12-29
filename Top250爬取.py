import re
import sqlite3
import urllib.request
import  urllib.error
import requests
from bs4 import BeautifulSoup
import xlwt
headers = {
    "User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
}
def main():
    url = 'https://movie.douban.com/top250?start='



    datalist = getData(url)
    savepath = ".\\Top250.xls"
    savedata(datalist,savepath)

findlink = re.compile(r'<a href="(.*?)">')
findTitle = re.compile(r'<span class="title">(.*)</span>')
findimg = re.compile(r'<img .*src="(.*?)" ',re.S)
findsroce = re.compile(r'<span class="rating_num" property="v:average">(.*)</span>')
findpeo = re.compile(r'<span>(.*)人评价</span>')
findinq = re.compile(r'<span class="inq">(.*)</span>')
findcon = re.compile(r'<p class="">(.*)</p>',re.S)

def getData(url):
    datalist=[]
    for i in range(0,250,50):
        html = askurl(url+str(i))
        soup = BeautifulSoup(html,"html.parser")
        for item in soup.find_all('div',class_="item"):
            # print(item)
            data = []
            item = str(item)
            link = re.findall(findlink,item)[0]
            data.append(link)
            img = re.findall(findimg, item)[0]
            data.append(img)
            title = re.findall(findTitle, item)
            if(len(title)==2):
                ctitle = title[0]
                data.append(ctitle)
                etitle = title[1].replace("/","")
                data.append(etitle)
            else:
                data.append(title[0])
                data.append(" ")
            rate = re.findall(findsroce,item)[0]
            data.append(rate)
            num = re.findall(findpeo,item)[0]
            # print(num)
            data.append(num)
            inq = re.findall(findinq,item)
            if(len(inq)!=0):
                inq = inq[0].replace(".","")
                data.append(inq)
            else:
                data.append(" ")
            bd = re.findall(findcon,item)[0]
            bd = re.sub('<br(\s+)?/>(\s+)?'," ",bd)
            bd = re.sub("/","",bd)
            data.append(bd.strip())
        datalist.append(data)
    return datalist

def askurl(url):
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
    }
    request = urllib.request.Request(url,headers=headers)
    html=""
    try:
        response = urllib.request.urlopen(request)
        html = response.read().decode("utf-8")
        # print(html)
    except urllib.error.URLError as e:
        if hasattr(e,"code"):
            print(e.code)
        if(hasattr(e,"reason")):
            print(e.reason)
    return html

def savedata(datalist,savepath):
    print("save---")
    print(datalist)
    workbook = xlwt.Workbook(encoding="utf-8",style_compression=0)
    worksheet = workbook.add_sheet("Top250",cell_overwrite_ok=True)
    col = ("电影详情链接","图片链接","影片中文名","影片外国名","评分","评价数","概况","相关信息")
    for i in range(0,8):
        worksheet.write(0,i,col[i])
    for i in range(1,251):
        print("第%d条" %i)
        data = datalist[i]
        worksheet.write(0, i, i)
        for j in range(8):
            worksheet.write(i,j,data[j])

    workbook.save("ces.xls")

main()