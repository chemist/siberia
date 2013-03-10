var admin = angular.module('admin', ['ngResource', 'ngCookies']);

admin.factory('Stream', function($resource){
    return $resource('/stream/:id', {'id': '@id'});
});

admin.controller('StreamsCtrl', function($scope, Stream){
    $scope.searchText = '';

    $scope.streams = [
        {id: 12, url: 'http://ru.ah.fm/'},
        {id: 13, url: 'http://bassjunkies.com'}
    ];

    //var streams = Stream.query(function(){
    //    console.log(streams);
    //    $scope.streams = streams;
    //});
});